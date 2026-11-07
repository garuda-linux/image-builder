# shellcheck shell=bash

LOOP=""
MNT=""

cleanup_lima() {
  if [[ -n "$MNT" ]]; then
    umount -R "$MNT" 2>/dev/null || true
    rmdir "$MNT" 2>/dev/null || true
  fi

  if [[ -n "$LOOP" ]]; then
    losetup -d "$LOOP" 2>/dev/null || true
  fi
}

post_lima() {
  local raw="$OUTPUT_DIR/garuda-lima.raw"
  [[ -f "$raw" ]] || die "$raw not found"

  trap cleanup_lima EXIT
  LOOP="$(losetup --find --show --partscan "$raw")"
  MNT="$(mktemp -d)"
  udevadm settle || true

  # Partition order from mkosi.profiles/lima/mkosi.repart
  local esp="${LOOP}p1" root="${LOOP}p2"
  local opts="noatime,compress=zstd"

  log "Mounting the Garuda btrfs layout"
  mount -o "subvol=@,$opts" "$root" "$MNT"

  local sv dir
  for sv in home:home root:root srv:srv cache:var/cache log:var/log tmp:var/tmp; do
    dir="${sv#*:}"
    mkdir -p "$MNT/$dir"
    mount -o "subvol=@${sv%%:*},$opts" "$root" "$MNT/$dir"
  done

  # The ESP at /efi, as on installs. /boot stays in @, so snapshots keep their kernel.
  mkdir -p "$MNT/efi"
  mount -o umask=0077 "$esp" "$MNT/efi"

  log "Writing fstab"
  check_presets "$MNT"
  genfstab -U "$MNT" >"$MNT/etc/fstab"

  # Without a udev database (build container) genfstab writes device paths
  # instead of UUIDs.
  local dev uuid
  for dev in "$esp" "$root"; do
    uuid="$(blkid -s UUID -o value "$dev")"
    [[ -n "$uuid" ]] || die "no filesystem UUID on $dev"
    sed -i "s|^${dev}[[:space:]]|UUID=${uuid}\t|" "$MNT/etc/fstab"
  done

  if grep -q '^/dev/loop' "$MNT/etc/fstab"; then
    die "fstab still has loop device paths"
  fi

  # Lima reads boot output from the serial console (serial.log)
  log "Writing the kernel command line"
  uuid="$(blkid -s UUID -o value "$root")"
  echo "root=UUID=$uuid rootflags=subvol=@ rw loglevel=3 quiet console=tty0 console=ttyS0,115200" \
    >"$MNT/etc/kernel/cmdline"

  log "Building initramfs, installing systemd-boot and the UKIs"
  arch-chroot "$MNT" dracut-rebuild

  # --no-variables: leaves the EFI variables of the build host alone. A fresh VM
  # boots EFI/BOOT/BOOTX64.EFI, which bootctl installs as well.
  # SYSTEMD_RELAX_ESP_CHECKS: the build container has no udev to confirm the
  # partition type of the loop device.
  arch-chroot "$MNT" env SYSTEMD_RELAX_ESP_CHECKS=1 \
    bootctl install --esp-path=/efi --no-variables
  arch-chroot "$MNT" env SYSTEMD_RELAX_ESP_CHECKS=1 /usr/lib/garuda/kernel-install-uki add

  compgen -G "$MNT/efi/EFI/Linux/garuda-*.efi" >/dev/null || die "no UKI in EFI/Linux of the Lima ESP"
  [[ -f "$MNT/efi/EFI/BOOT/BOOTX64.EFI" ]] || die "systemd-boot is missing on the Lima ESP"
  ls -l "$MNT/efi/EFI/Linux/"

  cleanup_lima
  LOOP="" MNT=""
  trap - EXIT

  log "Converting to qcow2"
  qemu-img convert -f raw -O qcow2 -c "$raw" "$OUTPUT_DIR/garuda-lima-$VERSION.qcow2"
  ln -sf "garuda-lima-$VERSION.qcow2" "$OUTPUT_DIR/garuda-lima.qcow2"

  log "Done: $OUTPUT_DIR/garuda-lima-$VERSION.qcow2"
}
