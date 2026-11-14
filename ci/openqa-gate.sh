#!/usr/bin/env bash
# Usage: ci/openqa-gate.sh <edition> <iso-url>
#   Runs the install scenario on OPENQA_HOST and waits. Exits 0 only if all
#   jobs passed. See docs/ci.md#openqa.

set -euo pipefail

edition="${1:?usage: ci/openqa-gate.sh <edition> <iso-url>}"
iso_url="${2:?usage: ci/openqa-gate.sh <edition> <iso-url>}"

for var in OPENQA_HOST OPENQA_API_KEY OPENQA_API_SECRET OPENQA_DISTRI_URL OPENQA_DISTRI_REF CI_PIPELINE_ID; do
  eval "value=\${$var:-}"
  [ -n "$value" ] || {
    echo "$var is not set, see docs/ci.md" >&2
    exit 1
  }
done

build="$CI_PIPELINE_ID"
version=image-builder

# Keep in sync with scenarios.sh of the test repository
scenarios="$(mktemp)"
trap 'rm -f "$scenarios"' EXIT
cat >"$scenarios" <<EOF
products:
  garuda-$edition:
    distri: garuda
    flavor: $edition
    arch: x86_64
    version: $version
machines:
  uefi:
    backend: qemu
    settings:
      WORKER_CLASS: qemu_x86_64
      UEFI: '1'
      UEFI_PFLASH_CODE: /usr/share/garuda-openqa/ovmf-code.bin
      UEFI_PFLASH_VARS: /usr/share/garuda-openqa/ovmf-vars.bin
      QEMUCPUS: '4'
job_templates:
  install:
    product: garuda-$edition
    machine: uefi
    settings:
      GARUDA_SCENARIO: install
      USBBOOT: '1'
      BOOTFROM: c
      HDDSIZEGB: '40'
      QEMURAM: '6144'
EOF

echo "Results: $OPENQA_HOST/tests/overview?distri=garuda&version=$version&build=$build"

# openqa-cli is Perl and block-buffers into the pipe, so awk would only see the
# job states once the job ended
PERL5OPT='-MIO::Handle;STDOUT->autoflush(1)' openqa-cli schedule --host "$OPENQA_HOST" \
  --apikey "$OPENQA_API_KEY" --apisecret "$OPENQA_API_SECRET" \
  --monitor --poll-interval 30 \
  --param-file SCENARIO_DEFINITIONS_YAML="$scenarios" \
  DISTRI=garuda VERSION="$version" FLAVOR="$edition" ARCH=x86_64 BUILD="$build" \
  EDITION="$edition" \
  ISO="garuda-$edition-$build.iso" ISO_URL="$iso_url" \
  CASEDIR="$OPENQA_DISTRI_URL#$OPENQA_DISTRI_REF" PRODUCTDIR=. NEEDLES_DIR='%%CASEDIR%%/needles' \
  __PIPELINE_URL="${CI_PIPELINE_URL:-}" |
  awk '
    /^\{"blocked_by_id"/ { if ($0 == json) next; json = $0 }
    /^Job state of job ID/ { sub(/, waiting.*/, ""); if ($0 == state) next; state = $0 }
    { print; fflush() }
  '
