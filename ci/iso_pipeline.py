#!/usr/bin/env python3
"""Writes the ISO child pipeline to stdout. Build triggers: docs/ci.md.

ci/iso_pipeline.py --stamp <edition> prints the stamp of an edition ISO."""

import hashlib
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
  image: alpine:3.22
  script:
    - echo "No edition changed, no ISO to build"
"""

ISO_JOB = """
iso:{edition}:
  stage: build
  image: $BUILDER_IMAGE
  tags: [nix-privileged]
  # Shared with .build in .gitlab-ci.yml: one build at a time on the build host
  resource_group: build-host
  # true in push pipelines only, a push must not cancel a schedule or release build
  interruptible: {interruptible}
  timeout: 3h
  retry:
    max: 1
    when: [runner_system_failure, stuck_or_timeout_failure]
  # Runs as root on the build host: protected refs only, as in .gitlab-ci.yml
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
    - export VERSION="${{CI_COMMIT_TAG:-$(date +%Y%m%d)}}"
    - ci/shared-state.sh
    - ./build.sh iso "$EDITION"
    - ci/package-changes.sh "iso:$EDITION" "mkosi.output/garuda-$EDITION.iso.manifest"
    # For publish:<edition>, after_script prunes the ISO from mkosi.output
    - |
      stage="/cache/publish/$EDITION/$CI_PIPELINE_ID"
      iso="$(readlink -f "mkosi.output/garuda-$EDITION.iso")"
      rm -rf "$stage"
      mkdir -p "$stage"
      cp --reflink=auto "$iso" "$iso.sha256" "mkosi.output/garuda-$EDITION.iso.manifest" \\
        "mkosi.output/garuda-$EDITION.iso.spdx.json" "$stage/"
      ln -s "${{iso##*/}}" "$stage/garuda-$EDITION.iso"
      ci/iso_pipeline.py --stamp "$EDITION" >"$stage/garuda-$EDITION.stamp"
    # For openqa:<edition>. The rename keeps the ISO of a running test intact.
    - |
      if [ -n "${{OPENQA_DISTRI_URL:-}}" ]; then
        iso="/cache/openqa/garuda-$EDITION.iso"
        mkdir -p /cache/openqa
        cp --reflink=auto "$(readlink -f "mkosi.output/garuda-$EDITION.iso")" "$iso.new"
        mv -f "$iso.new" "$iso"
        echo "$CI_PIPELINE_ID" >"$iso.pipeline"
      fi
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
    expire_in: 1 month

publish:{edition}:
  stage: publish
  image: $BUILDER_IMAGE
  tags: [nix-privileged] # /cache and /publish
  needs: ["iso:{edition}"]
  rules:
    - if: $CI_COMMIT_REF_PROTECTED != "true"
      when: never
    - when: on_success
  id_tokens:
    SIGSTORE_ID_TOKEN:
      aud: sigstore
  variables:
    EDITION: {edition}
  script:
    - stage="/cache/publish/$EDITION/$CI_PIPELINE_ID"
    - ci/publish-iso.sh "$EDITION" "$stage"
    - mkdir -p mkosi.output
    - find "$stage" -name '*.sigstore.json' -exec cp {{}} mkosi.output/ \\;
  after_script:
    - rm -rf "/cache/publish/$EDITION/$CI_PIPELINE_ID"
  artifacts:
    paths:
      - mkosi.output/garuda-{edition}-*.iso.sha256.sigstore.json
    expire_in: 1 month
"""


OPENQA_JOB = """
openqa:{edition}:
  stage: test
  image:
    # isotovideo with Inline::Python, from ci/openqa.Containerfile
    name: $OPENQA_IMAGE
    entrypoint: [""]
  tags: [nix-privileged] # KVM, the /cache volume with the ISO
  needs: ["iso:{edition}"]
  # One test VM (6 GB RAM, 4 CPUs) at a time, next to at most one ISO build
  resource_group: openqa-host
  interruptible: true
  timeout: 2h
  allow_failure: true
  rules:
    - if: $CI_COMMIT_REF_PROTECTED != "true"
      when: never
    - when: on_success
  variables:
    EDITION: {edition}
    GIT_STRATEGY: none
  script:
    - iso="/cache/openqa/garuda-$EDITION.iso"
    - test -f "$iso" || {{ echo "no ISO at $iso, the iso:$EDITION job copies it there"; exit 1; }}
    - >-
      test "$(cat "$iso.pipeline" 2>/dev/null)" = "$CI_PIPELINE_ID" ||
      {{ echo "$iso is from pipeline $(cat "$iso.pipeline" 2>/dev/null), not this one"; exit 1; }}
    # The tests run as root on the build host, so only a pinned tag or commit
    # of the test repository, never its newest branch
    - test -n "${{OPENQA_DISTRI_REF:-}}" || {{ echo "set OPENQA_DISTRI_REF to a tag or commit of the tests"; exit 1; }}
    - git init -q distri
    - git -C distri fetch -q --depth 1 "$OPENQA_DISTRI_URL" "$OPENQA_DISTRI_REF"
    - git -C distri checkout -q FETCH_HEAD
    - >-
      isotovideo CASEDIR="$PWD/distri" PRODUCTDIR="$PWD/distri" NEEDLES_DIR="$PWD/distri/needles"
      DISTRI=garuda EDITION="$EDITION" ARCH=x86_64 BACKEND=qemu ISO="$iso" USBBOOT=1 BOOTFROM=c
      UEFI=1 UEFI_PFLASH_CODE=/usr/share/garuda-openqa/ovmf-code.bin
      UEFI_PFLASH_VARS=/usr/share/garuda-openqa/ovmf-vars.bin
      QEMURAM=6144 QEMUCPUS=4 HDDSIZEGB=40 GARUDA_SCENARIO=install
  after_script:
    - iso="/cache/openqa/garuda-$EDITION.iso"
    - if [ "$(cat "$iso.pipeline" 2>/dev/null)" = "$CI_PIPELINE_ID" ]; then rm -f "$iso" "$iso.pipeline"; fi
  artifacts:
    when: always
    paths:
      - testresults/
      - video.ogv
      - autoinst-log.txt
      - serial0
    expire_in: 2 weeks
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


def requested(editions, value):
    # The string form of the editions array input: names in any brackets and quotes
    names = re.findall(r"[a-z0-9-]+", value)
    if "all" in names:
        return editions
    unknown = sorted(set(names) - set(editions))
    if unknown:
        sys.exit(f"Unknown editions in BUILD_EDITIONS: {' '.join(unknown)}")
    return sorted(set(names))


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

    selected = []
    if not all_editions:
        selected += [e for e in editions if f"[build {e}]" in message]

    # Against what is published, so the changes of a cancelled pipeline are not lost
    branch = env.get("CI_COMMIT_BRANCH", "")
    if not all_editions and branch and branch == env.get("CI_DEFAULT_BRANCH", ""):
        selected += [e for e in editions if stamp(e) != published_stamp(e)]

    if all_editions:
        selected = editions
    return sorted({e for e in selected if e})


def main():
    top = subprocess.run(["git", "rev-parse", "--show-toplevel"], stdout=subprocess.PIPE, text=True, check=True)
    os.chdir(top.stdout.rstrip("\n"))

    if sys.argv[1:2] == ["--stamp"]:
        print(stamp(sys.argv[2]))
        return

    selected = select(run("scripts/editions.sh"), os.environ)

    print("# Generated by ci/iso_pipeline.py")
    print("stages: [build, publish, test]")
    sys.stdout.flush()

    if not selected:
        print("Editions to build: none", file=sys.stderr)
        # A child pipeline needs at least one job
        sys.stdout.write(NO_ISO)
        return

    openqa = bool(os.environ.get("OPENQA_DISTRI_URL"))

    # balanced while CI is young. A release pipeline (web run or schedule) sets
    # ISO_COMPRESSION=max as a pipeline variable, iso:generate sees it here.
    compression = os.environ.get("ISO_COMPRESSION") or "balanced"
    interruptible = "true" if os.environ.get("CI_PIPELINE_SOURCE") == "push" else "false"
    print(
        f"Editions to build: {' '.join(selected)}, openQA: {'yes' if openqa else 'no'}, compression: {compression}",
        file=sys.stderr,
    )

    for edition in selected:
        sys.stdout.write(ISO_JOB.format(edition=edition, compression=compression, interruptible=interruptible))
        if openqa:
            sys.stdout.write(OPENQA_JOB.format(edition=edition))


if __name__ == "__main__":
    main()
