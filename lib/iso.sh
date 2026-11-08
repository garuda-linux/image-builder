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

# Children of a whiteout need no whiteout of their own. Neither do the children
# of a directory that the upper layer replaced with a file or symlink: overlayfs
# hides the lower directory behind it.
under_whiteout() {
  local out="$1" path="$2"
  while [[ "$path" == */* ]]; do
    path="${path%/*}"
    [[ -c "$out/$path" ]] && return 0
    [[ -L "$out/$path" || (-e "$out/$path" && ! -d "$out/$path") ]] && return 0
  done

  return 1
}

# Deleted files become overlayfs whiteouts (char device 0/0). The layers only
# work stacked in overlayfs. --checksum: mkosi clamps every mtime to
# SOURCE_DATE_EPOCH, so size and time cannot tell changed files apart.
make_layer_diff() {
  local lower="$1" upper="$2" out="$3"

  mkdir -p "$out" "$ISO_WORK/lists"
  rsync -aHAX --checksum --checksum-choice=xxh3 --compare-dest="$lower/" "$upper/" "$out/"

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

# A UUID derived from a name and SOURCE_DATE_EPOCH, for reproducible images
derived_uuid() {
  local h
  h="$(printf 'garuda-%s-%s' "$1" "$SOURCE_DATE_EPOCH" | sha256sum)"
  echo "${h:0:8}-${h:8:4}-${h:12:4}-${h:16:4}-${h:20:12}"
}

# Fixed times and a derived UUID make the image depend only on its content.
make_erofs() {
  mkfs.erofs --quiet "${EROFS_OPTS[@]}" -T"$SOURCE_DATE_EPOCH" \
    -U"$(derived_uuid "$3")" "$2" "$1"
}

# dm-verity hash tree of a layer image. The initrd opens the layer with the
# root hash from the boot entry, so every block read is checked. Salt and UUID
# are derived, so the hash image depends only on the layer image.
make_verity() {
  local data="$1" hash="$2" roothash="$3" name="$4" salt
  salt="$(printf 'garuda-verity-%s-%s' "$name" "$SOURCE_DATE_EPOCH" | sha256sum | cut -d' ' -f1)"
  rm -f "$hash" "$roothash"
  veritysetup format --data-block-size=4096 --hash-block-size=4096 \
    --salt="$salt" --uuid="$(derived_uuid "verity-$name")" \
    --root-hash-file="$roothash" "$data" "$hash" >/dev/null
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

# garuda.label= lets the initrd find the boot medium. garuda.verity= holds the
# dm-verity root hash of each layer, so every block read is checked. No quiet
# or splash, so boot messages stay visible. Each driver choice in three modes:
# normal, copied to RAM, with persistence. checksum=y reads the whole medium
# before the boot and stops with a clear message on a damaged block. The
# copytoram entries read the medium anyway, so they have it, and a last entry
# adds it to a normal boot, like the media check of other distributions. The
# options of an entry can be changed with e in the menu.
write_boot_menu() {
  local esp="$1" label="$2" verity="$3" edition="$4"
  local common="garuda.label=$label garuda.verity=$verity rd.systemd.gpt_auto=0 systemd.show_status=1"

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
      copytoram) mode_args=" copytoram checksum=y" mode_title=", copied to RAM" ;;
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

  n=$((n + 1))
  cat >"$esp/loader/entries/garuda-$n-verify.conf" <<ENTRY
title    Garuda Linux $edition: verify the medium, then boot (open source drivers)
sort-key garuda-$n
linux    /garuda/vmlinuz-x86_64
initrd   /garuda/amd-ucode.img
initrd   /garuda/intel-ucode.img
initrd   /garuda/initramfs-x86_64.img
options  $common driver=free nouveau.modeset=1 i915.modeset=1 radeon.modeset=1 checksum=y
ENTRY

  if [[ -f "$esp/garuda/memtest86x64.efi" ]]; then
    printf 'title    Memory test (memtest86+)\nsort-key zz-memtest\nefi      /garuda/memtest86x64.efi\n' \
      >"$esp/loader/entries/memtest.conf"
  fi
}

# The ESP is a GPT partition, which the El Torito boot catalog also points to.
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
  local tree="$1" label="$2" verity="$3" edition="$4"

  local kdirs=("$tree"/usr/lib/modules/*/)
  local kver
  kver="$(basename "${kdirs[0]}")"

  local esp="$ISO_WORK/esp"
  copy_boot_files "$tree" "$esp" "$kver"
  write_boot_menu "$esp" "$label" "$verity" "$edition"
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
      -f "$cache/$layer.verity" && -f "$cache/$layer.roothash" &&
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
      make_verity "$cache/$layer.erofs" "$cache/$layer.verity" "$cache/$layer.roothash" "$layer"
      echo "$key" >"$cache/$layer.key"
    fi

    cp --reflink=auto "$cache/$layer.erofs" "$layer_dir/$layer.erofs"
    cp --reflink=auto "$cache/$layer.verity" "$layer_dir/$layer.verity"
    cp "$cache/$layer.roothash" "$layer_dir/$layer.roothash"
  done
}

# garuda.verity= of the boot entries: <layer>:<root hash>,...
verity_arg() {
  local layer_dir="$1" layer arg=""
  for layer in "${ISO_LAYERS[@]}"; do
    arg="${arg:+$arg,}$layer:$(tr -d '[:space:]' <"$layer_dir/$layer.roothash")"
  done
  echo "$arg"
}

# The repart.d definitions of the ISO: the ESP, then each layer and its hash
# tree as partitions, found by the initrd by their names.
#
# The types follow the Discoverable Partitions Specification, so that
# systemd-dissect accepts the image. systemd-loop@.service runs it before it
# attaches a CD drive, see garuda-live-mount. The root layer is the root
# partition with its hash tree, both read-only (bit 60). The other layers are
# linux-generic with the no-auto flag (bit 63), which dissect skips: without
# it, eight generic partitions are eight root candidates and dissect refuses
# the image. NoAuto= of repart is ignored for linux-generic, so Flags= sets the
# bit. The live command line has rd.systemd.gpt_auto=0, so nothing mounts the
# root partition on its own.
write_repart_definitions() {
  local dir="$1" n=10 layer

  mkdir -p "$dir"
  printf '[Partition]\nType=esp\nCopyBlocks=/efiboot.img\n' >"$dir/00-esp.conf"

  for layer in "${ISO_LAYERS[@]}"; do
    if [[ "$layer" == root ]]; then
      printf '[Partition]\nType=root\nLabel=garuda-root\nReadOnly=yes\nGrowFileSystem=no\nCopyBlocks=/root.erofs\n' \
        >"$dir/$n-root.conf"
      printf '[Partition]\nType=root-verity\nLabel=garuda-root-verity\nReadOnly=yes\nCopyBlocks=/root.verity\n' \
        >"$dir/$((n + 1))-root-verity.conf"
    else
      printf '[Partition]\nType=linux-generic\nLabel=garuda-%s\nFlags=0x8000000000000000\nCopyBlocks=/%s.erofs\n' \
        "$layer" "$layer" >"$dir/$n-$layer.conf"
      printf '[Partition]\nType=linux-generic\nLabel=garuda-%s-verity\nFlags=0x8000000000000000\nCopyBlocks=/%s.verity\n' \
        "$layer" "$layer" >"$dir/$((n + 1))-$layer-verity.conf"
    fi
    n=$((n + 10))
  done
}

# UEFI only: a GPT disk image, which systemd-repart also makes a valid ISO 9660
# image whose El Torito boot catalog points to the ESP. systemd-boot has no BIOS
# support. The seed makes the partition and disk UUIDs reproducible.
write_iso() {
  local iso="$1" layer_dir="$2" label="$3"

  log "Writing $iso"
  cp --reflink=auto "$ISO_WORK/efiboot.img" "$layer_dir/efiboot.img"
  write_repart_definitions "$ISO_WORK/repart.d"

  rm -f "$iso"
  touch "$iso"
  systemd-repart --no-pager --offline=yes --dry-run=no --empty=allow --size=auto \
    --seed="$(derived_uuid "iso-$label")" \
    --root="$layer_dir" --definitions="$ISO_WORK/repart.d" \
    --el-torito=yes --el-torito-volume="$label" --el-torito-publisher="Garuda Linux" \
    "$iso" >"$ISO_WORK/repart.log" 2>&1 ||
    die "systemd-repart failed: $(tail -n 20 "$ISO_WORK/repart.log")"

  # VirtualBox takes only whole 2048-byte sectors. The backup GPT then moves to
  # the new end.
  local size
  size="$(stat -c %s "$iso")"
  if ((size % 2048)); then
    truncate --size=$(((size + 2047) / 2048 * 2048)) "$iso"
    sfdisk --quiet --relocate gpt-bak-std "$iso"
  fi

  # A broken write must not look like a successful build
  local need=0 f
  size="$(stat -c %s "$iso")"
  for f in "$layer_dir"/*.erofs "$layer_dir"/*.verity; do
    need=$((need + $(stat -c %s "$f")))
  done
  ((size > need)) || die "$iso is smaller than its layers"
}

# Only the newest ISO of an edition and kernel stays: one is 5 to 6 GB. The
# kernel in the pattern keeps dr460nized from matching dr460nized-gaming.
prune_isos() {
  local iso="$1" edition="$2" kernel="$3" old

  for old in "$OUTPUT_DIR/garuda-$edition-$kernel-"[0-9]*.iso; do
    [[ -e "$old" && "$old" != "$iso" ]] || continue
    log "Removing the older ${old##*/}"
    rm -f "$old" "$old.manifest" "$old.sha256" "$old.spdx.json"
  done
}

finish_iso() {
  local iso="$1" edition="$2" kernel="$3"

  prune_isos "$iso" "$edition" "$kernel"
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

  local layer_dir="$ISO_WORK/parts"

  # The layer images first: the boot entries carry their verity root hashes
  make_layer_images "$layer_dir"
  build_live_boot "$live" "$label" "$(verity_arg "$layer_dir")" "$edition"
  write_iso "$iso" "$layer_dir" "$label"
  finish_iso "$iso" "$edition" "$kernel"

  trap - EXIT
  cleanup_iso
  ISO_WORK=""

  log "Done: $iso"
}
