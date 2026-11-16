#!/usr/bin/env bash
# Usage: build verify <edition> [--version=<YYYYMMDD>]
#   Checks the ISO against its .sha256 file, then the Secure Boot signatures of
#   systemd-boot, the UKI and memtest on its ESP against the enrollment cert on
#   the same ESP. Unsigned builds have no cert and pass with a note.

set -euo pipefail

root="$(git rev-parse --show-toplevel)"
# shellcheck source=lib/env.sh
source "$root/lib/env.sh"
load_env_local "$root"

# shellcheck source=lib/log.sh
source "$root/lib/log.sh"
# shellcheck source=lib/args.sh
source "$root/lib/args.sh"
# shellcheck source=lib/images.sh
source "$root/lib/images.sh"

edition="${EDITION:-}"
version=""

for arg in "$@"; do
  case "$arg" in
    --version=*) version="${arg#--version=}" ;;
    --*) die "unknown option $arg" ;;
    *) edition="$arg" ;;
  esac
done

check_edition "$root" "$edition"
iso="$(image_path "$root" iso "$edition" "$version")"

log "Checksum of ${iso##*/}"
[[ -f "$iso.sha256" ]] || die "no $iso.sha256"
(cd "${iso%/*}" && sha256sum --check --quiet "${iso##*/}.sha256") || die "checksum mismatch"
echo "    OK"

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
esp="$iso@@$(esp_offset "$iso")"

if ! MTOOLS_SKIP_CHECK=1 mcopy -n -i "$esp" ::EFI/garuda/garuda-secureboot.cer "$work/cert.der" 2>/dev/null; then
  log "No EFI/garuda/garuda-secureboot.cer: an unsigned build, no signatures to check"
  exit 0
fi

command -v sbverify >/dev/null || die "the signature check needs sbverify (sbsigntools)"
openssl x509 -inform DER -in "$work/cert.der" -out "$work/cert.pem"
log "Signatures against $(openssl x509 -in "$work/cert.pem" -noout -subject)"

failed=0
for file in EFI/BOOT/grubx64.efi EFI/Linux/garuda.efi EFI/garuda/memtest86x64.efi; do
  if ! MTOOLS_SKIP_CHECK=1 mcopy -n -i "$esp" "::$file" "$work/check.efi" 2>/dev/null; then
    warn "$file is missing on the ESP"
    failed=1
    continue
  fi

  if sbverify --cert "$work/cert.pem" "$work/check.efi" >/dev/null 2>&1; then
    echo "    OK    $file"
  else
    echo "    FAIL  $file"
    failed=1
  fi
done

# shim is signed by Microsoft, not by the Garuda key
MTOOLS_SKIP_CHECK=1 mcopy -n -i "$esp" ::EFI/BOOT/BOOTX64.EFI "$work/shim.efi"
if sbverify --list "$work/shim.efi" 2>/dev/null | grep -q 'Microsoft'; then
  echo "    OK    EFI/BOOT/BOOTX64.EFI (shim, Microsoft signature)"
else
  echo "    FAIL  EFI/BOOT/BOOTX64.EFI has no Microsoft signature"
  failed=1
fi

((failed == 0)) || die "signature check failed"
log "All signatures valid"
