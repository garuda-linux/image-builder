# shellcheck shell=bash

readonly ISO_LAYERS=(root desktop mhwd live)

declare -rA EDITION_KERNEL=([xfce]=linux-lts)

ISO_WORK=""

cleanup_iso() {
  if [[ -n "$ISO_WORK" ]]; then
    rm -rf --one-file-system "$ISO_WORK"
  fi
}

# Edition kernel (iso-profiles profile.conf kernel=), unless -E KERNEL= is given.
# Prints the mkosi arguments one per line, for mapfile.
edition_args() {
  local edition="$1" arg
  shift

  [[ -n "${EDITION_KERNEL[$edition]:-}" ]] || return 0

  for arg in "$@"; do
    [[ "$arg" == KERNEL=* || "$arg" == *=KERNEL=* ]] && return 0
  done

  printf '%s\n' -E "KERNEL=${EDITION_KERNEL[$edition]}"
}

# ISO 9660 volume IDs hold at most 32 characters. The initrd finds the ISO by it.
iso_label() {
  local edition="$1" image_version="$2" label
  label="GARUDA_${edition^^}_$image_version"
  label="${label//-/}"
  echo "${label:0:32}"
}

# Children of a whiteout need no whiteout of their own
under_whiteout() {
  local out="$1" path="$2"
  while [[ "$path" == */* ]]; do
    path="${path%/*}"
    [[ -c "$out/$path" ]] && return 0
  done

  return 1
}

# Deleted files become overlayfs whiteouts (char device 0/0). The layers only
# work stacked in overlayfs.
make_layer_diff() {
  local lower="$1" upper="$2" out="$3"

  mkdir -p "$out" "$ISO_WORK/lists"
  rsync -aHAX --checksum --compare-dest="$lower/" "$upper/" "$out/"

  (cd "$lower" && find . -mindepth 1 | LC_ALL=C sort) >"$ISO_WORK/lists/lower"
  (cd "$upper" && find . -mindepth 1 | LC_ALL=C sort) >"$ISO_WORK/lists/upper"

  local path
  while IFS= read -r path; do
    under_whiteout "$out" "$path" && continue
    mkdir -p "$out/${path%/*}"
    mknod "$out/$path" c 0 0
  done < <(LC_ALL=C comm -23 "$ISO_WORK/lists/lower" "$ISO_WORK/lists/upper")
}

# max is slow to build but still fast to read in the live session.
# shellcheck disable=SC2054 # commas belong to the mkfs.erofs options
case "${ISO_COMPRESSION:=fast}" in
  fast) EROFS_OPTS=(-zlz4) ;;
  max) EROFS_OPTS=(-zzstd,level=22 -C1048576 -Ededupe,fragments,ztailpacking) ;;
  *) die "ISO_COMPRESSION must be fast or max, not $ISO_COMPRESSION" ;;
esac

# Fixed times and a UUID derived from layer and SOURCE_DATE_EPOCH make the
# image depend only on its content.
make_erofs() {
  local h
  h="$(printf 'garuda-%s-%s' "$3" "$SOURCE_DATE_EPOCH" | sha256sum)"
  mkfs.erofs --quiet "${EROFS_OPTS[@]}" -T"$SOURCE_DATE_EPOCH" \
    -U"${h:0:8}-${h:8:4}-${h:12:4}-${h:16:4}-${h:20:12}" "$2" "$1"
}

# systemd-boot reads kernels and initrds only from FAT, so everything it boots
# goes into the ESP image. The initrd has the modules of the root layer, so the
# kernels must match.
copy_boot_files() {
  local tree="$1" esp="$2" kver="$3" initrd
  initrd="$(layer_output live-initrd)"
  [[ -f "$initrd" ]] || die "$initrd not found"
  [[ -d "$OUTPUT_DIR/root/usr/lib/modules/$kver" ]] ||
    die "the live kernel $kver differs from the root layer kernel, and the initrd has the root layer modules"

  local sdboot="$tree/usr/lib/systemd/boot/efi/systemd-bootx64.efi"
  [[ -f "$sdboot" ]] || die "$sdboot missing in the live layer"

  mkdir -p "$esp/EFI/BOOT" "$esp/garuda" "$esp/loader/entries"
  install -m 0644 "$sdboot" "$esp/EFI/BOOT/BOOTX64.EFI"
  install -m 0644 "$tree/usr/lib/modules/$kver/vmlinuz" "$esp/garuda/vmlinuz-x86_64"
  install -m 0644 "$initrd" "$esp/garuda/initramfs-x86_64.img"

  local ucode
  for ucode in intel amd; do
    [[ -f "$tree/boot/$ucode-ucode.img" ]] || die "$tree/boot/$ucode-ucode.img missing, the boot entries load it"
    install -m 0644 "$tree/boot/$ucode-ucode.img" "$esp/garuda/$ucode-ucode.img"
  done

  if [[ -f "$tree/boot/memtest86+/memtest86x64.efi" ]]; then
    install -m 0644 "$tree/boot/memtest86+/memtest86x64.efi" "$esp/garuda/memtest86x64.efi"
  fi
}

# garuda.label= lets the initrd find the ISO. garuda.sums= pins SHA256SUMS of
# the layer files, checksum=y makes the initrd verify the layer files against
# it. No quiet or splash, so boot messages stay visible. Each driver choice in
# three modes: normal, copied to RAM, with persistence. The options of an entry
# can be changed with e in the menu.
write_boot_menu() {
  local esp="$1" label="$2" sums="$3" edition="$4"
  local common="garuda.label=$label garuda.sums=$sums rd.systemd.gpt_auto=0 systemd.show_status=1 checksum=y"

  log "Writing the systemd-boot menu"
  cat >"$esp/loader/loader.conf" <<CONF
timeout 10
default garuda-1-*
editor yes
auto-firmware yes
console-mode keep
CONF

  local n=0 mode mode_args mode_title driver driver_args driver_title
  for mode in normal copytoram persistence; do
    case "$mode" in
      normal) mode_args="" mode_title="" ;;
      copytoram) mode_args=" copytoram" mode_title=", copied to RAM" ;;
      persistence) mode_args=" persistence" mode_title=", with persistence" ;;
    esac
    for driver in free nonfree; do
      if [[ "$driver" == free ]]; then
        driver_args="driver=free nouveau.modeset=1 i915.modeset=1 radeon.modeset=1"
        driver_title="open source drivers"
      else
        driver_args="driver=nonfree nouveau.modeset=0 i915.modeset=1 radeon.modeset=1"
        driver_title="proprietary drivers (NVIDIA)"
      fi
      n=$((n + 1))
      cat >"$esp/loader/entries/garuda-$n-$driver-$mode.conf" <<ENTRY
title    Garuda Linux $edition: $driver_title$mode_title
sort-key garuda-$n
linux    /garuda/vmlinuz-x86_64
initrd   /garuda/amd-ucode.img
initrd   /garuda/intel-ucode.img
initrd   /garuda/initramfs-x86_64.img
options  $common $driver_args$mode_args
ENTRY
    done
  done

  if [[ -f "$esp/garuda/memtest86x64.efi" ]]; then
    printf 'title    Memory test (memtest86+)\nsort-key zz-memtest\nefi      /garuda/memtest86x64.efi\n' \
      >"$esp/loader/entries/memtest.conf"
  fi
}

# The ESP is the El Torito EFI image on CD and an appended GPT partition on USB.
# --invariant, -i and mcopy -m fix volume ID and file times for reproducibility.
make_efi_image() {
  local esp="$1" efi_img="$ISO_WORK/efiboot.img" efi_kib
  # FAT needs room for its tables and directories on top of the files
  efi_kib=$(($(du -sk --apparent-size "$esp" | cut -f1) * 105 / 100 + 8192))

  local mkfs_args=(
    --invariant
    -i "$(printf '%08X' $((SOURCE_DATE_EPOCH & 0xFFFFFFFF)))"
    -C
    -n GARUDA_EFI
  )

  rm -f "$efi_img"
  mkfs.fat "${mkfs_args[@]}" "$efi_img" "$efi_kib" >/dev/null

  find "$esp" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
  mcopy -s -m -i "$efi_img" "$esp"/* ::/
}

# post_iso checked that the live tree has exactly one kernel
build_live_boot() {
  local tree="$1" label="$2" sums="$3" edition="$4"

  local kdirs=("$tree"/usr/lib/modules/*/)
  local kver
  kver="$(basename "${kdirs[0]}")"

  local esp="$ISO_WORK/esp"
  copy_boot_files "$tree" "$esp" "$kver"
  write_boot_menu "$esp" "$label" "$sums" "$edition"
  make_efi_image "$esp"
}

# Cached per layer stamp and erofs options, so root.erofs is shared by all editions
make_layer_images() {
  local layer_dir="$1" cache="$OUTPUT_DIR/.erofs" layer key lower

  log "Making the layer images"
  mkdir -p "$layer_dir" "$cache"

  for layer in root desktop mhwd live; do
    key="$(printf '%s\n' "${NEW_STAMP[$layer]}" "${EROFS_OPTS[*]}" | sha256sum | cut -d' ' -f1)"

    if [[ -z "${REBUILT[$layer]:-}" && -f "$cache/$layer.erofs" &&
      "$(cat "$cache/$layer.key" 2>/dev/null)" == "$key" ]]; then
      log "Reusing $layer.erofs"
    else
      rm -f "$cache/$layer.key" "$cache/$layer.erofs"
      if [[ "$layer" == root ]]; then
        make_erofs "$OUTPUT_DIR/root" "$cache/root.erofs" root
      else
        lower=desktop
        [[ "$layer" == desktop ]] && lower=root
        make_layer_diff "$OUTPUT_DIR/$lower" "$OUTPUT_DIR/$layer" "$ISO_WORK/$layer.diff"
        make_erofs "$ISO_WORK/$layer.diff" "$cache/$layer.erofs" "$layer"
        rm -rf --one-file-system "$ISO_WORK/$layer.diff"
      fi
      echo "$key" >"$cache/$layer.key"
    fi

    cp --reflink=auto "$cache/$layer.erofs" "$layer_dir/$layer.erofs"
  done

  # For the checksum=y self-test in garuda-live-mount
  (cd "$layer_dir" && sha256sum ./*.erofs >SHA256SUMS)
}

# UEFI only, like archiso without BIOS: the ESP image is the El Torito EFI boot
# image on CD and GPT partition 2 on USB. systemd-boot has no BIOS support.
write_iso() {
  local iso="$1" isoroot="$2" layer_dir="$3" label="$4" edition="$5"

  log "Writing $iso"
  # xorriso applies SOURCE_DATE_EPOCH to volume dates only. File dates come
  # from the tree.
  find "$isoroot" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +

  local xorriso_args=(
    -as mkisofs -quiet
    -iso-level 3
    -full-iso9660-filenames
    -joliet
    -joliet-long
    -rational-rock
    -volid "$label"
    -appid "Garuda Linux $edition"
    -publisher "Garuda Linux"
    -preparer "image-builder"
    -partition_offset 16
    -append_partition 2 C12A7328-F81F-11D2-BA4B-00A0C93EC93B "$ISO_WORK/efiboot.img"
    -appended_part_as_gpt
    -eltorito-catalog boot.catalog
    -e --interval:appended_partition_2:all::
    -no-emul-boot
    -output "$iso"
  )

  rm -f "$iso"
  xorriso "${xorriso_args[@]}" "$isoroot" 2>"$ISO_WORK/xorriso.log" ||
    die "xorriso failed: $(tail -n 20 "$ISO_WORK/xorriso.log")"

  # A broken write must not look like a successful build
  local size need=0 f
  size="$(stat -c %s "$iso")"

  for f in "$layer_dir"/*.erofs; do
    need=$((need + $(stat -c %s "$f")))
  done

  ((size > need)) || die "$iso is smaller than its layers"
}

finish_iso() {
  local iso="$1" edition="$2"

  (cd "$OUTPUT_DIR" && sha256sum "${iso##*/}" >"${iso##*/}.sha256")

  install -m 0644 "$OUTPUT_DIR/live.manifest" "$iso.manifest"
  # Unversioned name, for comparing with the last build
  install -m 0644 "$OUTPUT_DIR/live.manifest" "$OUTPUT_DIR/garuda-$edition.iso.manifest"
  write_sbom "$iso.manifest" "garuda-$edition"
  install -m 0644 "$iso.spdx.json" "$OUTPUT_DIR/garuda-$edition.iso.spdx.json"

  ln -sf "${iso##*/}" "$OUTPUT_DIR/garuda-$edition.iso"
}

post_iso() {
  local edition="$1" layer

  for layer in "${ISO_LAYERS[@]}"; do
    [[ -d "$OUTPUT_DIR/$layer" ]] || die "$OUTPUT_DIR/$layer not found"
  done

  local live="$OUTPUT_DIR/live" kernel
  local kdirs=("$live"/usr/lib/modules/*/)
  [[ ${#kdirs[@]} -eq 1 && -d "${kdirs[0]}" ]] || die "expected exactly one kernel in $live"
  kernel="$(cat "${kdirs[0]}pkgbase")"

  ISO_WORK="$OUTPUT_DIR/iso-work"
  cleanup_iso
  mkdir -p "$ISO_WORK"
  trap cleanup_iso EXIT

  local iso="$OUTPUT_DIR/garuda-$edition-$kernel-$VERSION.iso" label
  label="$(iso_label "$edition" "$VERSION")"

  local isoroot="$ISO_WORK/iso"
  local layer_dir="$isoroot/garuda-live/layers"

  # The layer images first: the boot entries carry the hash of their SHA256SUMS
  make_layer_images "$layer_dir"
  local sums
  sums="$(sha256sum <"$layer_dir/SHA256SUMS")"
  build_live_boot "$live" "$label" "${sums%% *}" "$edition"
  write_iso "$iso" "$isoroot" "$layer_dir" "$label" "$edition"
  finish_iso "$iso" "$edition"

  trap - EXIT
  cleanup_iso
  ISO_WORK=""

  log "Done: $iso"
}
