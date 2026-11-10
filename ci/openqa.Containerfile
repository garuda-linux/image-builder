# openQA images for the Garuda tests, with Inline::Python, which isotovideo
# needs to load the Python test modules, and fixed OVMF paths. BASE selects:
# - isotovideo:qemu-kvm (default): isotovideo alone, for the openqa:<edition>
#   CI jobs and run-local.sh. The weekly schedule rebuilds it for updates.
# - openqa-single-instance: web UI, database and worker in one container, for
#   webui-local.sh of the test repository (needle editor, developer mode).
# Both are openSUSE Tumbleweed.
ARG BASE=registry.opensuse.org/devel/openqa/containers/isotovideo:qemu-kvm
FROM ${BASE}

LABEL org.opencontainers.image.title="garuda openQA" \
      org.opencontainers.image.source="https://gitlab.com/garuda-linux/tools/image-builder"

# Package versions are not pinned: Tumbleweed is rolling and zypper resolves the versions of the base image.
# hadolint ignore=DL3037
RUN zypper -n install --no-recommends 'perl(Inline::Python)' qemu-ovmf-x86_64 \
    && zypper -n clean --all \
    && perl -MInline::Python -e 1

# Fixed firmware paths for UEFI_PFLASH_CODE and UEFI_PFLASH_VARS: the file names
# of qemu-ovmf-x86_64 differ between openSUSE versions. Without Secure Boot keys.
RUN set -e; \
    link() { \
        name="$1"; shift; \
        for f in "$@"; do \
            if [ -f "/usr/share/qemu/$f" ]; then ln -s "/usr/share/qemu/$f" "/usr/share/garuda-openqa/$name"; return 0; fi; \
        done; \
        echo "no OVMF file for $name in /usr/share/qemu:"; ls /usr/share/qemu; return 1; \
    }; \
    mkdir -p /usr/share/garuda-openqa; \
    link ovmf-code.bin ovmf-x86_64-4m-code.bin ovmf-x86_64-code.bin; \
    link ovmf-vars.bin ovmf-x86_64-4m-vars.bin ovmf-x86_64-vars.bin; \
    ls -l /usr/share/garuda-openqa

# Only the openqa-single-instance base has openqa-bootstrap, its entrypoint. On
# every start it refreshes the repositories and installs its packages, which
# upgrades openQA to the newest build. That upgrade fails on the read-only ISO
# mount of webui-local.sh (rpm cannot chown /var/lib/openqa/share/factory/iso).
# The image has all of them, so the step only runs when one is missing.
# $packages stays literal: openqa-bootstrap expands it when it sources the line.
# hadolint ignore=SC2016
RUN b=/usr/share/openqa/script/openqa-bootstrap; \
    if [ -f "$b" ]; then \
        grep -q '^retry -e -s 30 -r 7 -- sh -c "zypper' "$b" || { echo "zypper step not found in $b"; exit 1; }; \
        sed -i 's|^retry -e -s 30 -r 7 -- sh -c "zypper|rpm -q --quiet $packages \|\| &|' "$b"; \
        grep -n 'rpm -q --quiet' "$b"; \
    fi
