#!/usr/bin/env bash
# Usage: iso-test <edition> [--cdrom] [--disk] [--boot-disk] [--secure-boot] [--keep] [--serial]
#                 [--ram=<size>] [--version=<YYYYMMDD>]
#   Boots the ISO with systemd-vmspawn in a window, with UEFI and a TPM, as a
#   virtio disk. The VM writes to an overlay, so the ISO stays unchanged.
#   --cdrom        attach the ISO as a SCSI CD drive instead
#   --disk         add a 30G install disk for Calamares
#   --boot-disk    boot the install disk without the ISO
#   --secure-boot  Secure Boot on, with the Microsoft keys enrolled and the
#                  cert of the ISO in MokList, as on a PC after the enrollment.
#                  Signed ISOs only.
#   --keep         reuse the live overlay and firmware variables of the last run
#   --serial       console in this terminal instead of a window
#   --ram=<size>   RAM of the VM, default TEST_RAM or 6G. copytoram needs the layer files plus 2 GiB.
#   --version=<v>  an older ISO of the edition, see build ls
#   The edition defaults to EDITION, the CPU count to TEST_CPUS or 4.

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
cdrom=false
disk=false
boot_disk=false
secure_boot=false
keep=false
console=gui
ram="${TEST_RAM:-6G}"
version=""

for arg in "$@"; do
  case "$arg" in
    --cdrom) cdrom=true ;;
    --disk) disk=true ;;
    --boot-disk) boot_disk=true ;;
    --secure-boot) secure_boot=true ;;
    --keep) keep=true ;;
    --serial) console=interactive ;;
    --ram=*) ram="${arg#--ram=}" ;;
    --version=*) version="${arg#--version=}" ;;
    --*) die "unknown option $arg" ;;
    *) edition="$arg" ;;
  esac
done

check_edition "$root" "$edition"
ram="$(ram_mib "$ram")M"

iso=""
if [[ "$boot_disk" == false || "$secure_boot" == true ]]; then
  iso="$(image_path "$root" iso "$edition" "$version")"
fi

# build.sh creates it, mkosi.cache belongs to root
state="$root/mkosi.cache/qemu"
disk_image="$state/iso-test-disk.qcow2"
overlay="$state/iso-test-live.qcow2"
vars="$state/iso-test-vars.fd"
tpm="$state/iso-test-tpm"
journal="$state/iso-test-journal"

check_state_dir "$state"

# The TPM belongs to the install disk, so a TPM enrolled by the installer
# stays valid for --boot-disk
if [[ ("$disk" == true || "$boot_disk" == true) && ! -e "$disk_image" ]]; then
  rm -rf "$tpm"
  qemu-img create -q -f qcow2 "$disk_image" 30G
fi

rm -rf "$journal"
mkdir -p "$journal"

[[ "$keep" == true && -e "$vars" ]] || rm -f "$vars"

# Fresh firmware variables unless --keep. With --secure-boot: a generated PK,
# the Microsoft KEK and db certificates, and the ISO cert in MokList (owner is
# the shim GUID), so shim starts systemd-boot without MokManager.
secure_boot_arg=no
if [[ "$secure_boot" == true ]]; then
  # The enrollment cert from the ESP of the ISO, so it always matches the signature
  MTOOLS_SKIP_CHECK=1 mcopy -n -i "$iso@@$(esp_offset "$iso")" ::EFI/garuda/garuda-secureboot.cer "$state/iso-test-cert.der" 2>/dev/null ||
    die "$iso has no EFI/garuda/garuda-secureboot.cer: not a signed build"

  if [[ ! -e "$vars" ]]; then
    template="$(systemd-vmspawn --firmware=describe --firmware-features=secure-boot |
      jq -r '.mapping["nvram-template"].filename')"

    virt-fw-vars --input "$template" --output "$vars" --loglevel WARNING \
      --enroll-generate "Garuda iso-test PK" --microsoft-kek all --microsoft-db all --sb \
      --add-mok 605dab50-e046-4300-abb6-3dd810dd8b23 "$state/iso-test-cert.der"
  fi

  secure_boot_arg=yes
fi

args=(
  --firmware=uefi --secure-boot="$secure_boot_arg" --efi-nvram-state="$vars"
  --tpm=yes --tpm-state="$tpm"
  --ram="$ram" --cpus="${TEST_CPUS:-4}"
  --console="$console"
  --network-user-mode
  --register=no
  --forward-journal="$journal/"
)

if [[ "$boot_disk" == true ]]; then
  args+=(--image="$disk_image" --image-format=qcow2)
else
  # A writable overlay on the root-owned ISO, which vmspawn cannot open read-only
  if [[ "$keep" == false || ! -e "$overlay" ]]; then
    rm -f "$overlay"
    qemu-img create -q -f qcow2 -F raw -b "$iso" "$overlay"
  fi

  disk_type=virtio-blk
  [[ "$cdrom" == true ]] && disk_type=scsi-cd
  args+=(--image="$overlay" --image-format=qcow2 --image-disk-type="$disk_type")

  if [[ "$disk" == true ]]; then
    args+=(--extra-drive="qcow2:virtio-blk:$disk_image")
  fi
fi

[[ -z "$iso" ]] || log "ISO: $iso"
log "Journal: journalctl --directory=$journal"
exec systemd-vmspawn "${args[@]}"
