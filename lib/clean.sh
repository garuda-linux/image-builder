# shellcheck shell=bash
# build.sh clean <level> [--yes], levels in docs/building.md#cleaning-up. Each
# level includes the ones above it. Kept at every level: the current images,
# mkosi.cache/qemu (the test VMs) and mkosi.packages/.

readonly CLEAN_LEVELS=(old layers caches all)

# Versioned top-level files that no link in mkosi.output points to, together
# with the files beside them (.sha256, .manifest, .spdx.json)
clean_old_images() {
  local file name target keep targets=()

  for file in "$OUTPUT_DIR"/*; do
    [[ -L "$file" ]] && targets+=("$(readlink "$file")")
  done

  for file in "$OUTPUT_DIR"/*; do
    name="${file##*/}"
    [[ -f "$file" && ! -L "$file" && "$name" =~ -20[0-9]{6}[.-] ]] || continue
    keep=false

    for target in "${targets[@]}"; do
      if [[ "$name" == "$target" || "$name" == "$target".* ]]; then
        keep=true
        break
      fi
    done

    [[ "$keep" == true ]] || echo "$file"
  done
}

stale_layers() {
  local file name

  for file in "$STAMPS"/* "$OUTPUT_DIR"/.erofs/* "$OUTPUT_DIR"/*.vmlinuz; do
    [[ -f "$file" ]] || continue
    name="${file##*/}"
    name="${name%.*}"
    if [[ -n "$name" && "$name" != garuda-* && -z "${LAYER_BELOW[$name]+known}" ]]; then
      echo "$name"
    fi
  done | sort -u
}

clean_paths() {
  local level="$1" layer stale=()

  clean_old_images
  echo "$PWD/mkosi.cache/repro"
  [[ "$level" == old ]] && return

  mapfile -t stale < <(stale_layers)
  for layer in "${!LAYER_BELOW[@]}" "${stale[@]}"; do
    echo "$OUTPUT_DIR/$layer"
    layer_output "$layer"
    echo "$OUTPUT_DIR/$layer.vmlinuz"
    echo "$OUTPUT_DIR/$layer.manifest"
  done

  echo "$OUTPUT_DIR/.erofs"

  echo "$OUTPUT_DIR/.oci-work"
  echo "$OUTPUT_DIR/.oci-cache"
  for layer in "$OUTPUT_DIR"/garuda-*-tree; do
    echo "$layer"
  done

  echo "$STAMPS"
  [[ "$level" == layers ]] && return

  local cache
  for cache in mkosi.cache/*.cache mkosi.cache/*.manifest mkosi.cache/tmp; do
    echo "$PWD/$cache"
  done
  [[ "$level" == caches ]] && return

  echo "$PWD/mkosi.cache/packages"
  echo "$PWD/mkosi.cache/shim"
  echo "$PWD/mkosi.tools"
  echo "$PWD/mkosi.tools.manifest"
  echo "$PWD/mkosi.workspace"
  echo "$OUTPUT_DIR/.secureboot"
  echo "$TIMINGS_FILE"
  echo "$PWD/$SANDBOX/usr"
  echo "$PWD/$SANDBOX/etc/pacman.d/chaotic-mirrorlist"
}

clean_main() {
  local level="${1:-}" yes=false path paths=() answer

  [[ " ${CLEAN_LEVELS[*]} " == *" $level "* ]] || die "clean needs a level: ${CLEAN_LEVELS[*]}"
  [[ "${2:-}" == --yes ]] && yes=true

  while read -r path; do
    [[ -e "$path" || -L "$path" ]] && paths+=("$path")
  done < <(clean_paths "$level" | sort -u)

  if ((${#paths[@]} == 0)); then
    log "Nothing to clean for $level"
    return
  fi

  du -sch -- "${paths[@]}" 2>/dev/null | sed "s|$PWD/||"
  if [[ "$yes" != true ]]; then
    read -rp "Remove these? [y/N] " answer </dev/tty
    [[ "$answer" == [yY]* ]] || return 0
  fi

  remove_output "${paths[@]}"
  log "Removed ${#paths[@]} paths ($level)"
}
