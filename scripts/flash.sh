#!/usr/bin/env bash
# Usage: build flash <edition> <device> [--version=<YYYYMMDD>] [--yes]
#   Writes the ISO of the edition to a USB stick, for example /dev/sdb. Refuses
#   partitions, disks with a mounted filesystem or active swap (this covers the
#   system disk) and disks smaller than the ISO. Shows the disk and asks first,
#   --yes skips the question.

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

edition=""
device=""
version=""
yes=false

for arg in "$@"; do
  case "$arg" in
    --version=*) version="${arg#--version=}" ;;
    --yes) yes=true ;;
    --*) die "unknown option $arg" ;;
    /dev/*) device="$arg" ;;
    *) edition="$arg" ;;
  esac
done

edition="${edition:-${EDITION:-}}"
[[ -n "$device" ]] || die "usage: build flash <edition> <device> [--version=<YYYYMMDD>] [--yes]"
check_edition "$root" "$edition"
iso="$(image_path "$root" iso "$edition" "$version")"

[[ -b "$device" ]] || die "$device is not a block device"
[[ "$(lsblk -dno TYPE "$device")" == disk ]] || die "$device is not a whole disk, give the disk instead of a partition"

mounted="$(lsblk -nro MOUNTPOINTS "$device" | grep -v '^$' || true)"
[[ -z "$mounted" ]] || die "$device is in use: $(tr '\n' ' ' <<<"$mounted"). Unmount it first"

iso_size="$(stat -Lc %s "$iso")"
disk_size="$(lsblk -dbno SIZE "$device")"
((disk_size >= iso_size)) || die "$device ($((disk_size / 1048576)) MiB) is smaller than the ISO ($((iso_size / 1048576)) MiB)"

log "ISO: $iso ($((iso_size / 1048576)) MiB)"
lsblk -o NAME,MODEL,SIZE,TRAN,RM,FSTYPE,LABEL "$device"

if [[ "$(lsblk -dno RM "$device" | tr -d ' ')" != 1 && "$(lsblk -dno TRAN "$device")" != usb ]]; then
  warn "$device is an internal disk, not a removable or USB one"
fi

if [[ "$yes" != true ]]; then
  read -rp "Overwrite everything on $device? [y/N] " answer </dev/tty
  [[ "$answer" == [yY]* ]] || exit 0
fi

sudo dd if="$iso" of="$device" bs=4M oflag=direct conv=fsync status=progress
log "Wrote $edition to $device"
