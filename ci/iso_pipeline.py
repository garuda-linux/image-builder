#!/usr/bin/env python3
"""Writes the ISO child pipeline to stdout. Build triggers: docs/ci.md.

ci/iso_pipeline.py --stamp <edition> prints the stamp of an edition ISO."""

import hashlib
import json
import os
import re
import subprocess
import sys
import urllib.request

STAMP_PATHS = [
    "mkosi.conf",
    "mkosi.conf.d",
    "mkosi.sandbox",
    "mkosi.shared",
    "mkosi.profiles/iso",
    "mkosi.images",
    "build.sh",
    "lib/timings.sh",
    "lib/chaotic.sh",
    "lib/layers.sh",
    "lib/secureboot.sh",
    "lib/iso.sh",
    "scripts/sbom.py",
    "ci/Containerfile",
]

PUBLISHED = "https://iso.builds.garudalinux.org/iso/image-builder/{edition}/latest/garuda-{edition}.stamp"

NO_ISO = """\
no-iso:
  stage: build
  image: alpine:3.24
  script:
    - echo "No edition changed, no ISO to build"
"""

ISO_JOB = """
iso:{edition}:
  stage: build
  image: $BUILDER_IMAGE
  tags: [nix-privileged]
  resource_group: build-host
  interruptible: {interruptible}
  timeout: {timeout}
  retry:
    max: 1
    when: [runner_system_failure]
  environment:
    name: signing
    action: access
  rules:
    - if: $CI_COMMIT_REF_PROTECTED != "true"
      when: never
    - when: on_success
  variables:
    EDITION: {edition}
    ISO_COMPRESSION: {compression}
    RUNNER_GENERATE_ARTIFACTS_METADATA: "true"
  script:
    # A release tag is its date (YYYYMMDD), the ISO carries it as its version
    - |
      case "${{CI_COMMIT_TAG:-}}" in
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) export VERSION="$CI_COMMIT_TAG" ;;
        *) export VERSION="$(date +%Y%m%d)" ;;
      esac
    - ci/shared-state.sh
    - ./build.sh iso "$EDITION"
    - ci/package-changes.sh "iso:$EDITION" "mkosi.output/garuda-$EDITION.iso.manifest"
    # after_script prunes the ISO from mkosi.output
    - |
      stage="{staging}"
      iso="$(readlink -f "mkosi.output/garuda-$EDITION.iso")"
      rm -rf "$stage"
      mkdir -p "$stage"
      cp --reflink=auto "$iso" "$iso.sha256" "mkosi.output/garuda-$EDITION.iso.manifest" \\
        "mkosi.output/garuda-$EDITION.iso.spdx.json" "$stage/"
      ln -s "${{iso##*/}}" "$stage/garuda-$EDITION.iso"
      ci/iso_pipeline.py --stamp "$EDITION" >"$stage/garuda-$EDITION.stamp"
      chmod -R a+rX "$stage"
      echo "ISO_NAME=${{iso##*/}}" >iso.env
  after_script:
    - ci/shared-state.sh save-tools
    - ci/shared-state.sh prune
  # The ISO (about 5 GB) exceeds the artifact size limit and stays on the runner host
  artifacts:
    paths:
      - mkosi.output/garuda-{edition}.iso.manifest
      - mkosi.output/garuda-{edition}.iso.manifest.changes
      - mkosi.output/garuda-{edition}.iso.spdx.json
      - mkosi.output/garuda-{edition}-*.iso.sha256
    reports:
      dotenv: iso.env
    expire_in: 1 month

publish:{edition}:
  stage: publish
  image: $BUILDER_IMAGE
  tags: [nix-privileged] # /publish
  needs: {publish_needs}
  rules:
    - if: $CI_COMMIT_REF_PROTECTED != "true"
      when: never
    - when: on_success
  id_tokens:
    SIGSTORE_ID_TOKEN:
      aud: sigstore
  variables:
    EDITION: {edition}
    GIT_DEPTH: 1
  script:
    - stage="{staging}"
    - ci/publish-iso.sh "$EDITION" "$stage"
    - mkdir -p mkosi.output
    - find "$stage" -name '*.sigstore.json' -exec cp {{}} mkosi.output/ \\;
  artifacts:
    paths:
      - mkosi.output/garuda-{edition}-*.iso.sha256.sigstore.json
    expire_in: 1 month

cleanup:{edition}:
  stage: cleanup
  image: $BUILDER_IMAGE
  tags: [nix-privileged] # /publish
  needs: {cleanup_needs}
  rules:
    - if: $CI_COMMIT_REF_PROTECTED != "true"
      when: never
    - when: on_success
  variables:
    EDITION: {edition}
    GIT_STRATEGY: none
  script:
    - rm -rf "{staging}"
"""

STAGING = "/publish/iso/$EDITION/staging/$CI_PIPELINE_ID"
STAGING_URL = "https://iso.builds.garudalinux.org/iso/image-builder/$EDITION/staging/$CI_PIPELINE_ID"

# Their base or root layer differs (lite, linux-lts): last, so the shared layers are rebuilt once per run
BUILD_LAST = ["kde-lite", "xfce"]

MIRROR_KINDS = ("release", "latest")
MIRROR_ROOTS = ("image-builder", "image-builder-test")
TIMEOUTS = {"fast": "1h", "balanced": "1h", "max": "3h"}


OPENQA_JOB = """
openqa:{edition}:
  stage: test
  image: $OPENQA_CLIENT_IMAGE
  needs: ["iso:{edition}"]
  # So the timeout counts the test, not the openQA queue
  resource_group: openqa-aerialis
  interruptible: true
  timeout: 2h
  rules:
    - if: $CI_COMMIT_REF_PROTECTED != "true"
      when: never
    - when: on_success
  variables:
    EDITION: {edition}
  script:
    - bash ci/openqa-gate.sh "$EDITION" "{staging_url}/$ISO_NAME"
"""


MIRROR_JOB = """
mirror:{edition}:
  stage: mirror
  image: $BUILDER_IMAGE
  tags: [nix-privileged] # /publish
  needs: [{{"job": "publish:{edition}", "artifacts": false}}]
  allow_failure: true
  rules:
    - if: $CI_COMMIT_REF_PROTECTED != "true"
      when: never
    - if: $R2_RCLONE_CONFIG == null && $SOURCEFORGE_SSH_KEY == null
      when: never
    - if: $CI_COMMIT_TAG =~ /^[0-9]{{8}}$/
      when: on_success
    - if: $CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH
      when: manual
  variables:
    EDITION: {edition}
    GIT_DEPTH: 1
    MIRROR_KIND: {kind}
    MIRROR_ROOT: {root}
    MIRROR_DRY_RUN: "{dry_run}"
  script:
    - ci/mirror-iso.sh "$EDITION"
"""


def run(*args):
    # A failing command fails the generator job, instead of an empty list
    # turning into the no-iso job
    return subprocess.run(args, stdout=subprocess.PIPE, text=True, check=True).stdout.splitlines()


def in_stamp(path, edition):
    parts = path.split("/")
    if "mkosi.profiles" in parts[:-1] and parts[0] == "mkosi.images":
        return parts[parts.index("mkosi.profiles") + 1] == edition
    return True


def stamp(edition):
    entries = run("git", "ls-files", "--stage", "--", *STAMP_PATHS)
    digest = hashlib.sha256(f"{edition}\n".encode())
    for entry in entries:
        if in_stamp(entry.split("\t", 1)[1], edition):
            digest.update(f"{entry}\n".encode())
    return digest.hexdigest()


def published_stamp(edition):
    try:
        with urllib.request.urlopen(PUBLISHED.format(edition=edition), timeout=30) as response:
            return response.read().decode().strip()
    except OSError as error:
        # Not published yet, or the mirror is down: build rather than skip
        print(f"No published stamp for {edition}: {error}", file=sys.stderr)
        return None


def ordered(names):
    return sorted(set(names), key=lambda name: (BUILD_LAST.index(name) if name in BUILD_LAST else -1, name))


def requested(editions, value):
    # The string form of the editions array input: names in any brackets and quotes
    names = re.findall(r"[a-z0-9-]+", value)
    if "all" in names:
        return ordered(editions)
    unknown = sorted(set(names) - set(editions))
    if unknown:
        sys.exit(f"Unknown editions in BUILD_EDITIONS: {' '.join(unknown)}")
    return ordered(names)


def select(editions, env):
    # The ISO jobs run as root on the build host: nothing to build on unprotected refs
    if env.get("CI_COMMIT_REF_PROTECTED", "") != "true":
        return []

    chosen = requested(editions, env.get("BUILD_EDITIONS", ""))
    if chosen or env.get("CI_PIPELINE_SOURCE", "") in ("trigger", "pipeline"):
        return chosen

    message = env.get("CI_COMMIT_MESSAGE", "")
    all_editions = env.get("CI_PIPELINE_SOURCE", "") in ("schedule", "web")

    # A date tag (YYYYMMDD) is a release of every edition, see ci/publish-iso.sh.
    if re.fullmatch(r"\d{8}", env.get("CI_COMMIT_TAG", "")):
        all_editions = True
    if re.search(r"\[build (all|iso)\]", message):
        all_editions = True

    if all_editions:
        return ordered(editions)

    tagged = [e for e in editions if f"[build {e}]" in message]

    if tagged:
        return ordered(tagged)

    # Against what is published, so the changes of a cancelled pipeline are not lost
    branch = env.get("CI_COMMIT_BRANCH", "")

    if branch and branch == env.get("CI_DEFAULT_BRANCH", ""):
        return ordered(e for e in editions if stamp(e) != published_stamp(e))

    return []


def main():
    top = subprocess.run(["git", "rev-parse", "--show-toplevel"], stdout=subprocess.PIPE, text=True, check=True)
    os.chdir(top.stdout.rstrip("\n"))

    if sys.argv[1:2] == ["--stamp"]:
        print(stamp(sys.argv[2]))
        return

    selected = select(run("scripts/editions.sh"), os.environ)

    print("# Generated by ci/iso_pipeline.py")
    print("stages: [build, test, publish, mirror, cleanup]")
    sys.stdout.flush()

    if not selected:
        print("Editions to build: none", file=sys.stderr)
        # A child pipeline needs at least one job
        sys.stdout.write(NO_ISO)
        return

    openqa = bool(os.environ.get("OPENQA_DISTRI_URL"))

    compression = os.environ.get("ISO_COMPRESSION") or "balanced"
    if compression not in TIMEOUTS:
        sys.exit(f"ISO_COMPRESSION must be fast, balanced or max, not {compression!r}")
    kind = os.environ.get("MIRROR_KIND") or "release"
    if kind not in MIRROR_KINDS:
        sys.exit(f"MIRROR_KIND must be release or latest, not {kind!r}")
    root = os.environ.get("MIRROR_ROOT") or "image-builder"
    if root not in MIRROR_ROOTS:
        sys.exit(f"MIRROR_ROOT must be image-builder or image-builder-test, not {root!r}")
    dry_run = os.environ.get("MIRROR_DRY_RUN") or "false"
    if dry_run not in ("true", "false"):
        sys.exit(f"MIRROR_DRY_RUN must be true or false, not {dry_run!r}")
    interruptible = "true" if os.environ.get("CI_PIPELINE_SOURCE") == "push" else "false"
    print(
        f"Editions to build: {' '.join(selected)}, openQA: {'yes' if openqa else 'no'}, compression: {compression}",
        file=sys.stderr,
    )

    for edition in selected:
        iso, test, publish = f"iso:{edition}", f"openqa:{edition}", f"publish:{edition}"
        publish_needs = [iso, test] if openqa else [iso]
        cleanup_needs = [{"job": job, "artifacts": False} for job in [*publish_needs, publish]]

        sys.stdout.write(
            ISO_JOB.format(
                edition=edition,
                compression=compression,
                timeout=TIMEOUTS[compression],
                interruptible=interruptible,
                staging=STAGING,
                publish_needs=json.dumps(publish_needs),
                cleanup_needs=json.dumps(cleanup_needs),
            )
        )

        if openqa:
            sys.stdout.write(OPENQA_JOB.format(edition=edition, staging_url=STAGING_URL))

        sys.stdout.write(
            MIRROR_JOB.format(edition=edition, kind=kind, root=root, dry_run="1" if dry_run == "true" else "")
        )


if __name__ == "__main__":
    main()
