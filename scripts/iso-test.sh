#!/usr/bin/env bash
# shellcheck disable=SC2054 # QEMU options are comma-separated
# Usage: iso-test [edition] [--cdrom] [--disk] [--boot-disk] [--ram=<size>]
#   --cdrom      attach the ISO as a CD drive instead of a USB stick
#   --disk       add a 30G install disk for Calamares
#   --boot-disk  boot the install disk without the ISO
#   --ram=<size> RAM of the VM, default 6G. copytoram needs the layer files plus 2 GiB.

set -euo pipefail

root="$(git rev-parse --show-toplevel)"
edition=mokka
cdrom=false
disk=false
boot_disk=false
ram=6G

for arg in "$@"; do
  case "$arg" in
    --cdrom) cdrom=true ;;
    --disk) disk=true ;;
    --boot-disk) boot_disk=true ;;
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

iso="$root/mkosi.output/garuda-$edition.iso"
# build.sh creates it, mkosi.cache belongs to root
state="$root/mkosi.cache/qemu"
disk_image="$state/iso-test-disk.qcow2"
if ! mkdir -p "$state" 2>/dev/null || [[ ! -w "$state" ]]; then
  echo "$state is not writable. A build creates it, or: sudo install -d -o $USER $state" >&2
  exit 1
fi

args=(
  -enable-kvm -machine q35 -cpu host -m "$ram" -smp 4
  -vga virtio -display gtk
  -nic user,model=virtio-net-pci
  -serial "file:$state/iso-serial.log"
  -device qemu-xhci
)

# UEFI only: the ISO and installs boot systemd-boot. edk2 ships with QEMU. The
# vars file must be writable, so each run gets a fresh copy.
share="$(dirname "$(readlink -f "$(command -v qemu-system-x86_64)")")/../share/qemu"
install -m 0644 "$share/edk2-i386-vars.fd" "$state/iso-test-vars.fd"
args+=(
  -drive "if=pflash,format=raw,readonly=on,file=$share/edk2-x86_64-code.fd"
  -drive "if=pflash,format=raw,file=$state/iso-test-vars.fd"
)

if [[ "$boot_disk" == false ]]; then
  if [[ ! -e "$iso" ]]; then
    echo "No ISO at $iso. Run: build iso $edition" >&2
    exit 1
  fi

  args+=(-drive "if=none,id=live,format=raw,readonly=on,file=$(readlink -f "$iso")")
  if [[ "$cdrom" == true ]]; then
    args+=(-device ide-cd,drive=live,bootindex=0)
  else
    args+=(-device usb-storage,drive=live,bootindex=0)
  fi
fi

if [[ "$disk" == true || "$boot_disk" == true ]]; then
  if [[ ! -e "$disk_image" ]]; then
    qemu-img create -f qcow2 "$disk_image" 30G
  fi
  args+=(-drive "if=virtio,format=qcow2,file=$disk_image")
fi

echo "Serial log: $state/iso-serial.log"
exec qemu-system-x86_64 "${args[@]}"
