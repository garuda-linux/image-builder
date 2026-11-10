#!/usr/bin/env bash
# Usage: iso-test [edition] [--cdrom] [--disk] [--boot-disk] [--secure-boot] [--ram=<size>]
#   Boots the ISO with systemd-vmspawn in a window, with UEFI and a TPM, as a
#   virtio disk. The VM writes to an overlay, so the ISO stays unchanged.
#   --cdrom        attach the ISO as a SCSI CD drive instead
#   --disk         add a 30G install disk for Calamares
#   --boot-disk    boot the install disk without the ISO
#   --secure-boot  Secure Boot on, with the Microsoft keys enrolled and the
#                  cert of the ISO in MokList, as on a PC after the enrollment.
#                  Signed ISOs only.
#   --ram=<size>   RAM of the VM, default 6G. copytoram needs the layer files plus 2 GiB.

set -euo pipefail

root="$(git rev-parse --show-toplevel)"
edition=mokka
cdrom=false
disk=false
boot_disk=false
secure_boot=false
ram=6G

for arg in "$@"; do
  case "$arg" in
    --cdrom) cdrom=true ;;
    --disk) disk=true ;;
    --boot-disk) boot_disk=true ;;
    --secure-boot) secure_boot=true ;;
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
overlay="$state/iso-test-live.qcow2"
tpm="$state/iso-test-tpm"
journal="$state/iso-test-journal"

if ! mkdir -p "$state" 2>/dev/null || [[ ! -w "$state" ]]; then
  echo "$state is not writable. A build creates it, or: sudo install -d -o $USER $state" >&2
  exit 1
fi

# The TPM belongs to the install disk, so a TPM enrolled by the installer
# stays valid for --boot-disk
if [[ ("$disk" == true || "$boot_disk" == true) && ! -e "$disk_image" ]]; then
  rm -rf "$tpm"
  qemu-img create -q -f qcow2 "$disk_image" 30G
fi

vars="$state/iso-test-vars.fd"
rm -rf "$journal" "$vars"
mkdir -p "$journal"

# The enrollment cert from the ESP of the ISO, so it always matches the signature
iso_cert() {
  local out="$1" table offset
  table="$(sfdisk --json "$iso")"
  offset="$(jq -r '.partitiontable as $t | $t.partitions[]
    | select(.type == "C12A7328-F81F-11D2-BA4B-00A0C93EC93B") | .start * ($t.sectorsize // 512)' <<<"$table")"
  [[ "$offset" =~ ^[0-9]+$ ]] || {
    echo "No ESP found in $iso" >&2
    exit 1
  }
  MTOOLS_SKIP_CHECK=1 mcopy -n -i "$iso@@$offset" ::EFI/garuda/garuda-secureboot.cer "$out" 2>/dev/null || {
    echo "$iso has no EFI/garuda/garuda-secureboot.cer: not a signed build" >&2
    exit 1
  }
}

# Fresh firmware variables on every run. With --secure-boot: a generated PK,
# the Microsoft KEK and db certificates, and the ISO cert in MokList (owner is
# the shim GUID), so shim starts systemd-boot without MokManager.
secure_boot_arg=no
if [[ "$secure_boot" == true ]]; then
  [[ -e "$iso" ]] || {
    echo "--secure-boot takes the cert from the ISO. No ISO at $iso. Run: build iso $edition" >&2
    exit 1
  }

  iso_cert "$state/iso-test-cert.der"
  template="$(systemd-vmspawn --firmware=describe --firmware-features=secure-boot |
    jq -r '.mapping["nvram-template"].filename')"

  virt-fw-vars --input "$template" --output "$vars" --loglevel WARNING \
    --enroll-generate "Garuda iso-test PK" --microsoft-kek all --microsoft-db all --sb \
    --add-mok 605dab50-e046-4300-abb6-3dd810dd8b23 "$state/iso-test-cert.der"
  secure_boot_arg=yes
fi

args=(
  --firmware=uefi --secure-boot="$secure_boot_arg" --efi-nvram-state="$vars"
  --tpm=yes --tpm-state="$tpm"
  --ram="$ram" --cpus=4
  --console=gui
  --network-user-mode
  --register=no
  --forward-journal="$journal/"
)

if [[ "$boot_disk" == true ]]; then
  args+=(--image="$disk_image" --image-format=qcow2)
else
  if [[ ! -e "$iso" ]]; then
    echo "No ISO at $iso. Run: build iso $edition" >&2
    exit 1
  fi

  # A writable overlay on the root-owned ISO, which vmspawn cannot open read-only
  rm -f "$overlay"
  qemu-img create -q -f qcow2 -F raw -b "$(readlink -f "$iso")" "$overlay"
  disk_type=virtio-blk
  [[ "$cdrom" == true ]] && disk_type=scsi-cd
  args+=(--image="$overlay" --image-format=qcow2 --image-disk-type="$disk_type")
  if [[ "$disk" == true ]]; then
    args+=(--extra-drive="qcow2:virtio-blk:$disk_image")
  fi
fi

echo "Journal: journalctl --directory=$journal"
exec systemd-vmspawn "${args[@]}"
