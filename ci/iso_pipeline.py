#!/usr/bin/env python3
"""Writes the ISO child pipeline to stdout. Build triggers: docs/ci.md."""

import os
import re
import subprocess
import sys
from fnmatch import fnmatchcase

# Shell globs, where * also matches /. A change to any of them rebuilds every edition.
# Keep in sync with the shared anchor under .paths in .gitlab-ci.yml, see docs/ci.md
SHARED = [
    "mkosi.conf",
    "mkosi.conf.d/*",
    "mkosi.sandbox/*",
    "mkosi.images/base/*",
    "mkosi.images/root/*",
    "mkosi.images/mhwd/*",
    "mkosi.images/live-initrd/*",
    "mkosi.profiles/iso/*",
    "build.sh",
    "lib/*",
    "mkosi.shared/*",
    "scripts/sbom.py",
    ".gitlab-ci.yml",
    "ci/*",
    "scripts/editions.sh",
    "scripts/boot-check.sh",
]
for layer in ("desktop", "live"):
    SHARED += [
        f"mkosi.images/{layer}/mkosi.conf",
        f"mkosi.images/{layer}/mkosi.conf.d/*",
        f"mkosi.images/{layer}/mkosi.extra*/*",  # also the shared trees such as mkosi.extra.plasma
        f"mkosi.images/{layer}/mkosi.postinst.chroot",
    ]

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
  interruptible: true
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
    ISO_COMPRESSION: max # smallest ISO, local builds default to fast lz4
    RUNNER_GENERATE_ARTIFACTS_METADATA: "true"
  script:
    - export VERSION="$(date +%Y%m%d)"
    - ./build.sh iso "$EDITION"
    - ci/package-changes.sh "iso:$EDITION" "mkosi.output/garuda-$EDITION.iso.manifest"
    # For openqa:<edition>: the next job starts with a clean workspace, the
    # /cache volume of the runner outlives it
    - |
      if [ -n "${{OPENQA_DISTRI_URL:-}}" ]; then
        mkdir -p "/cache/openqa/$CI_PIPELINE_ID"
        cp --reflink=auto "$(readlink -f "mkosi.output/garuda-$EDITION.iso")" \\
          "/cache/openqa/$CI_PIPELINE_ID/garuda-$EDITION.iso"
      fi
  # The ISO (about 5 GB) exceeds the artifact size limit and stays on the runner host
  artifacts:
    paths:
      - mkosi.output/garuda-{edition}.iso.manifest
      - mkosi.output/garuda-{edition}.iso.manifest.changes
      - mkosi.output/garuda-{edition}.iso.spdx.json
      - mkosi.output/garuda-{edition}-*.iso.sha256
    expire_in: 1 month
"""


OPENQA_JOB = """
openqa:{edition}:
  stage: test
  image:
    name: registry.opensuse.org/devel/openqa/containers/isotovideo:qemu-kvm
    entrypoint: [""]
  tags: [nix-privileged] # KVM, the /cache volume with the ISO
  needs: ["iso:{edition}"]
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
    - iso="/cache/openqa/$CI_PIPELINE_ID/garuda-$EDITION.iso"
    - test -f "$iso" || {{ echo "no ISO at $iso, the iso:$EDITION job copies it there"; exit 1; }}
    - git clone --depth 1 "$OPENQA_DISTRI_URL" distri
    - >-
      isotovideo CASEDIR="$PWD/distri" PRODUCTDIR="$PWD/distri" NEEDLES_DIR="$PWD/distri/needles"
      DISTRI=garuda EDITION="$EDITION" ARCH=x86_64 BACKEND=qemu ISO="$iso" USBBOOT=1
      UEFI=1 UEFI_PFLASH_CODE=/usr/share/qemu/ovmf-x86_64-code.bin UEFI_PFLASH_VARS=/usr/share/qemu/ovmf-x86_64-vars.bin
      QEMURAM=6144 QEMUCPUS=4
  after_script:
    - rm -f "/cache/openqa/$CI_PIPELINE_ID/garuda-$EDITION.iso"
    - rmdir "/cache/openqa/$CI_PIPELINE_ID" 2>/dev/null || true
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


def has_commit(sha):
    if re.fullmatch(r"0+", sha):
        return False
    probe = subprocess.run(["git", "cat-file", "-e", f"{sha}^{{commit}}"], stderr=subprocess.DEVNULL)
    return probe.returncode == 0


def select(editions, env):
    # The ISO jobs run as root on the build host: nothing to build on unprotected refs
    if env.get("CI_COMMIT_REF_PROTECTED", "") != "true":
        return []

    message = env.get("CI_COMMIT_MESSAGE", "")
    all_editions = env.get("CI_PIPELINE_SOURCE", "") in ("schedule", "web")
    if re.search(r"\[build (all|iso)\]", message):
        all_editions = True

    selected = []
    if not all_editions:
        selected += [e for e in editions if f"[build {e}]" in message]

    branch = env.get("CI_COMMIT_BRANCH", "")
    if not all_editions and branch and branch == env.get("CI_DEFAULT_BRANCH", ""):
        before = env.get("CI_COMMIT_BEFORE_SHA") or "0" * 40
        if not has_commit(before):
            # No previous commit to diff against
            all_editions = True
        else:
            for path in run("git", "diff", "--name-only", before, env.get("CI_COMMIT_SHA") or "HEAD"):
                if any(fnmatchcase(path, pattern) for pattern in SHARED):
                    all_editions = True
                selected += [e for e in editions if fnmatchcase(path, f"mkosi.images/*/mkosi.profiles/{e}/*")]

    if all_editions:
        selected = editions
    return sorted({e for e in selected if e})


def main():
    top = subprocess.run(["git", "rev-parse", "--show-toplevel"], stdout=subprocess.PIPE, text=True, check=True)
    os.chdir(top.stdout.rstrip("\n"))
    selected = select(run("scripts/editions.sh"), os.environ)

    print("# Generated by ci/iso_pipeline.py")
    print("stages: [build, test]")
    sys.stdout.flush()

    if not selected:
        print("Editions to build: none", file=sys.stderr)
        # A child pipeline needs at least one job
        sys.stdout.write(NO_ISO)
        return

    openqa = bool(os.environ.get("OPENQA_DISTRI_URL"))
    print(f"Editions to build: {' '.join(selected)}, openQA: {'yes' if openqa else 'no'}", file=sys.stderr)
    for edition in selected:
        sys.stdout.write(ISO_JOB.format(edition=edition))
        if openqa:
            sys.stdout.write(OPENQA_JOB.format(edition=edition))


if __name__ == "__main__":
    main()
