#!/usr/bin/env bash
# shellcheck disable=SC2054 # QEMU options are comma-separated
# Usage: vm-test [edition] [--keep] [--ram=<size>] [--vga=<type>]
#   Boots mkosi.output/garuda-vm-<edition>.qcow2 in a QEMU window with UEFI,
#   as virt-manager does. The VM writes to an overlay in ~/.cache/image-builder,
#   so the built image stays unchanged.
#   --keep        reuse the overlay and firmware variables of the last run
#                 instead of starting from the built image
#   --ram=<size>  RAM of the VM, default 6G
#   --vga=<type>  graphics of the VM, default virtio as in virt-manager, std
#                 for the plain VGA of QEMU

set -euo pipefail

root="$(git rev-parse --show-toplevel)"
edition=mokka
keep=false
ram=6G
vga=virtio

for arg in "$@"; do
  case "$arg" in
    --keep) keep=true ;;
    --ram=*) ram="${arg#--ram=}" ;;
    --vga=*) vga="${arg#--vga=}" ;;
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

state="${XDG_CACHE_HOME:-$HOME/.cache}/image-builder"
overlay="$state/vm-test-$edition.qcow2"
vars="$state/vm-test-$edition-vars.fd"
mkdir -p "$state"

# UEFI only, as the image boots systemd-boot. edk2 ships with QEMU.
share="$(dirname "$(readlink -f "$(command -v qemu-system-x86_64)")")/../share/qemu"

# A fresh overlay on the built image and fresh firmware variables, unless --keep.
# The overlay has the virtual size of the image, systemd-repart grows root to it.
if [[ "$keep" == false || ! -e "$overlay" || ! -e "$vars" ]]; then
  rm -f "$overlay"
  qemu-img create -q -f qcow2 -F qcow2 -b "$(readlink -f "$image")" "$overlay"
  install -m 0644 "$share/edk2-i386-vars.fd" "$vars"
fi

args=(
  -enable-kvm -machine q35 -cpu host -m "$ram" -smp 4
  -vga "$vga" -display gtk
  -nic user,model=virtio-net-pci
  -serial "file:$state/vm-serial.log"
  # Kernel and systemd messages also to the serial log, without changing the
  # image: systemd-stub appends this to the command line of the UKI (only
  # without Secure Boot, which this VM does not have). QEMU takes ,, for a comma
  # inside an option value.
  -smbios "type=11,value=io.systemd.stub.kernel-cmdline-extra=console=tty0 console=ttyS0,,115200 systemd.show_status=1"
  -drive "if=pflash,format=raw,readonly=on,file=$share/edk2-x86_64-code.fd"
  -drive "if=pflash,format=raw,file=$vars"
  -drive "if=virtio,format=qcow2,file=$overlay"
)

echo "Image: $(readlink -f "$image")"
echo "Overlay: $overlay"
echo "Serial log: $state/vm-serial.log"
echo "Login: garuda / garuda"
exec qemu-system-x86_64 "${args[@]}"
