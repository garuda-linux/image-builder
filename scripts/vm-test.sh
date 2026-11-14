#!/usr/bin/env bash
# Usage: vm-test [edition] [--keep] [--ram=<size>]
#   Boots mkosi.output/garuda-vm-<edition>.qcow2 with systemd-vmspawn in a
#   window, with UEFI and a TPM. The VM writes to an overlay in mkosi.cache/qemu,
#   so the built image stays unchanged.
#   --keep        reuse the overlay, firmware variables and TPM of the last run
#                 instead of starting from the built image
#   --ram=<size>  RAM of the VM, default TEST_RAM or 6G

set -euo pipefail

root="$(git rev-parse --show-toplevel)"
# shellcheck source=lib/env.sh
source "$root/lib/env.sh"
load_env_local "$root"
edition=mokka
keep=false
ram="${TEST_RAM:-6G}"

for arg in "$@"; do
  case "$arg" in
    --keep) keep=true ;;
    --ram=*) ram="${arg#--ram=}" ;;
    --*)
      echo "Unknown option $arg" >&2
      exit 1
      ;;
    *) edition="$arg" ;;
  esac
done

if [[ ! -d "$root/mkosi.images/desktop/mkosi.profiles/$edition" ]]; then
  echo "unknown edition $edition, see scripts/editions.sh" >&2
  exit 1
fi

image="$root/mkosi.output/garuda-vm-$edition.qcow2"
if [[ ! -e "$image" ]]; then
  echo "No VM image at $image. Run: build vm $edition" >&2
  exit 1
fi

# build.sh creates it, mkosi.cache belongs to root
state="$root/mkosi.cache/qemu"
overlay="$state/vm-test-$edition.qcow2"
vars="$state/vm-test-$edition-vars.fd"
tpm="$state/vm-test-$edition-tpm"
journal="$state/vm-test-journal"

if ! mkdir -p "$state" 2>/dev/null || [[ ! -w "$state" ]]; then
  echo "$state is not writable. A build creates it, or: sudo install -d -o $USER $state" >&2
  exit 1
fi

# The overlay has the virtual size of the image, systemd-repart grows root to it
if [[ "$keep" == false || ! -e "$overlay" ]]; then
  rm -rf "$overlay" "$vars" "$tpm"
  qemu-img create -q -f qcow2 -F qcow2 -b "$(readlink -f "$image")" "$overlay"
fi

rm -rf "$journal"
mkdir -p "$journal"

# UEFI without Secure Boot: the UKIs of the image are built on it, unsigned
args=(
  --image="$overlay" --image-format=qcow2
  --firmware=uefi --secure-boot=no --efi-nvram-state="$vars"
  --tpm=yes --tpm-state="$tpm"
  --ram="$ram" --cpus=4
  --console=gui
  --network-user-mode
  --register=no
  --forward-journal="$journal/"
)

echo "Image: $(readlink -f "$image")"
echo "Overlay: $overlay"
echo "Journal: journalctl --directory=$journal"
echo "Login: garuda / garuda"
exec systemd-vmspawn "${args[@]}"
