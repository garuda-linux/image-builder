# shellcheck shell=bash
# Disk images with the Garuda btrfs layout (Lima, VM): what Calamares does on
# an install, done on the raw image that mkosi wrote from mkosi.repart.
# Partition 1 is the ESP, partition 2 the btrfs root with the @ subvolumes.

DISK_LOOP=""
DISK_MNT=""
DISK_NODES=()

disk_cleanup() {
  if [[ -n "$DISK_MNT" ]]; then
    umount -R "$DISK_MNT" 2>/dev/null || true
    rmdir "$DISK_MNT" 2>/dev/null || true
  fi

  if [[ -n "$DISK_LOOP" ]]; then
    losetup -d "$DISK_LOOP" 2>/dev/null || true
  fi

  if ((${#DISK_NODES[@]} > 0)); then
    rm -f "${DISK_NODES[@]}"
  fi
  DISK_LOOP="" DISK_MNT="" DISK_NODES=()
}

# Without udev (CI container) the kernel adds the loop partitions, but nothing
# creates their nodes in /dev. They are made from sysfs here.
disk_partition_nodes() {
  local loop="${DISK_LOOP#/dev/}" part node major minor

  for part in /sys/block/"$loop"/"$loop"p*; do
    [[ -r "$part/dev" ]] || continue

    node="/dev/${part##*/}"
    [[ -b "$node" ]] && continue

    IFS=: read -r major minor <"$part/dev"
    mknod "$node" b "$major" "$minor"

    DISK_NODES+=("$node")
  done

  [[ -b "${DISK_LOOP}p2" ]] || die "no partition 2 on $DISK_LOOP"
}

# disk_mount <raw>: mounts the subvolumes and the ESP at /efi under DISK_MNT
disk_mount() {
  local raw="$1"
  [[ -f "$raw" ]] || die "$raw not found"

  trap disk_cleanup EXIT
  DISK_LOOP="$(losetup --find --show --partscan "$raw")"
  DISK_MNT="$(mktemp -d)"
  udevadm settle || true
  disk_partition_nodes

  local root="${DISK_LOOP}p2" opts="noatime,compress=zstd"

  log "Mounting the Garuda btrfs layout"
  mount -o "subvol=@,$opts" "$root" "$DISK_MNT"

  local sv dir
  for sv in home:home root:root srv:srv cache:var/cache log:var/log tmp:var/tmp; do
    dir="${sv#*:}"
    mkdir -p "$DISK_MNT/$dir"
    mount -o "subvol=@${sv%%:*},$opts" "$root" "$DISK_MNT/$dir"
  done

  # The ESP at /efi, as on installs. /boot stays in @, so snapshots keep their kernel.
  mkdir -p "$DISK_MNT/efi"
  mount -o umask=0077 "${DISK_LOOP}p1" "$DISK_MNT/efi"
}

# The filesystem UUID of partition <n> of the mounted image
disk_uuid() {
  local uuid
  uuid="$(blkid -s UUID -o value "${DISK_LOOP}p$1")"
  [[ -n "$uuid" ]] || die "no filesystem UUID on ${DISK_LOOP}p$1"
  echo "$uuid"
}

disk_fstab() {
  log "Writing fstab"
  check_presets "$DISK_MNT"
  genfstab -U "$DISK_MNT" >"$DISK_MNT/etc/fstab"

  # Without a udev database (build container) genfstab writes device paths
  # instead of UUIDs.
  local n dev
  for n in 1 2; do
    dev="${DISK_LOOP}p$n"
    sed -i "s|^${dev}[[:space:]]|UUID=$(disk_uuid "$n")\t|" "$DISK_MNT/etc/fstab"
  done

  if grep -q '^/dev/loop' "$DISK_MNT/etc/fstab"; then
    die "fstab still has loop device paths"
  fi
}

# disk_boot <kernel options>: /etc/kernel/cmdline with root= in front, then the
# initramfs, systemd-boot and the UKIs, with the entry token of
# /etc/kernel/entry-token, as the image has no machine ID yet
disk_boot() {
  log "Writing the kernel command line"
  echo "root=UUID=$(disk_uuid 2) rootflags=subvol=@ rw $*" >"$DISK_MNT/etc/kernel/cmdline"

  log "Building initramfs, installing systemd-boot and the UKIs"
  arch-chroot "$DISK_MNT" dracut-rebuild

  # --no-variables: leaves the EFI variables of the build host alone. A fresh VM
  # boots EFI/BOOT/BOOTX64.EFI, which bootctl installs as well.
  # SYSTEMD_RELAX_ESP_CHECKS: the build container has no udev to confirm the
  # partition type of the loop device.
  arch-chroot "$DISK_MNT" env SYSTEMD_RELAX_ESP_CHECKS=1 \
    bootctl install --esp-path=/efi --no-variables
  arch-chroot "$DISK_MNT" env SYSTEMD_RELAX_ESP_CHECKS=1 /usr/lib/garuda/kernel-install-uki add

  local token
  token="$(cat "$DISK_MNT/etc/kernel/entry-token")"
  compgen -G "$DISK_MNT/efi/EFI/Linux/$token-*.efi" >/dev/null || die "no UKI in EFI/Linux of the ESP"
  [[ -f "$DISK_MNT/efi/EFI/BOOT/BOOTX64.EFI" ]] || die "systemd-boot is missing on the ESP"
  ls -l "$DISK_MNT/efi/EFI/Linux/"
}

disk_unmount() {
  disk_cleanup
  trap - EXIT
}

# disk_qcow2 <raw> <name> [virtual size]: <name>-VERSION.qcow2 plus <name>.qcow2
# as link to it, both in OUTPUT_DIR. The raw image (3 GB and more) and the
# link mkosi made to it go, the qcow2 holds the same content.
disk_qcow2() {
  local raw="$1" name="$2" size="${3:-}" qcow2="$OUTPUT_DIR/$2-$VERSION.qcow2"

  log "Converting to qcow2"
  qemu-img convert -f raw -O qcow2 -c -o compression_type=zstd "$raw" "$qcow2"
  if [[ -n "$size" ]]; then
    qemu-img resize "$qcow2" "$size" >/dev/null
  fi
  ln -sf "${qcow2##*/}" "$OUTPUT_DIR/$name.qcow2"

  rm -f "$raw"
  [[ -L "${raw%.raw}" ]] && rm -f "${raw%.raw}"

  log "Done: $qcow2"
}
