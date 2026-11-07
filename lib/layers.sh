# shellcheck shell=bash

# mkosi 27 turns Incremental= off for images on BaseTrees=, so only base gets
# a package snapshot. Each layer gets a stamp instead: a hash of its inputs and
# the stamp of the layer below. Unchanged layers are reused across editions.
readonly STAMPS="$OUTPUT_DIR/.stamps"

# Quoted keys: shfmt would turn an unquoted live-initrd into arithmetic
declare -rA LAYER_BELOW=(["base"]="" ["root"]=base ["desktop"]=root ["live"]=desktop ["mhwd"]=desktop ["live-initrd"]=root)

declare -A NEW_STAMP=() REBUILT=()

# --fresh passes --force twice, which also drops the package snapshot of the
# base layer.
FORCE=()

# GARUDA_BUILD_LIVE_INITRD for live-initrd
build_var() {
  local name="${1^^}"
  echo "GARUDA_BUILD_${name//-/_}"
}

# Layers without their variable do not match, so mkosi neither builds nor
# depends on them. The output profiles then depend on the matched layers.
run_mkosi() {
  local layer env_args=()

  for layer in "${!REBUILT[@]}"; do
    env_args+=(--environment="$(build_var "$layer")=1")
  done

  log "mkosi $* (version $VERSION)"
  mkosi --image-version="$VERSION" "${env_args[@]}" "$@" "${FORCE[@]}" build
}

hash_files() {
  local path existing=()

  for path in "$@"; do
    [[ -e "$path" ]] && existing+=("$path")
  done

  if ((${#existing[@]} == 0)); then
    echo none
    return
  fi
  find "${existing[@]}" -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1
}

layer_files_hash() {
  local layer="$1" edition="$2" dir="mkosi.images/$1" paths=()
  mapfile -t paths < <(find "$dir" -mindepth 1 -maxdepth 1 ! -name mkosi.profiles)
  [[ -n "$edition" ]] && paths+=("$dir/mkosi.profiles/$edition")
  hash_files "${paths[@]}"
}

layer_output() {
  case "$1" in
    live-initrd) echo "$OUTPUT_DIR/live-initrd.cpio.zst" ;;
    *) echo "$OUTPUT_DIR/$1" ;;
  esac
}

# Outputs may be btrfs subvolumes, which rm -rf also removes as root
remove_output() {
  local path
  for path in "$@"; do
    if [[ -e "$path" || -L "$path" ]]; then
      rm -rf -- "$path"
    fi
  done
}

prepare_layers() {
  local edition="$1" layers=() layer below stamp global lite=no

  shift
  while [[ "$1" != -- ]]; do
    layers+=("$1")
    shift
  done
  shift

  [[ "$edition" == kde-lite ]] && lite=yes # kde-lite skips the 50-extra.conf files
  global="$(printf '%s\n' "$(hash_files mkosi.conf mkosi.conf.d mkosi.local.conf mkosi.shared "$SANDBOX")" \
    "$(mkosi --version)" "lite=$lite" "$*" | sha256sum | cut -d' ' -f1)"

  mkdir -p "$STAMPS"
  for layer in "${layers[@]}"; do
    below="${LAYER_BELOW[$layer]}"
    stamp="$(printf '%s\n' "$global" "${below:+${NEW_STAMP[$below]}}" \
      "$(layer_files_hash "$layer" "$edition")" | sha256sum | cut -d' ' -f1)"
    NEW_STAMP[$layer]="$stamp"

    if ((${#FORCE[@]} == 0)) && [[ -e "$(layer_output "$layer")" ]] &&
      [[ -z "$below" || -z "${REBUILT[$below]:-}" ]] &&
      [[ "$(cat "$STAMPS/$layer" 2>/dev/null)" == "$stamp" ]]; then
      log "Reusing the $layer layer"
    else
      REBUILT[$layer]=1
      rm -f "$STAMPS/$layer"
      remove_output "$OUTPUT_DIR/$layer" "$(layer_output "$layer")"
    fi
  done
}

write_stamps() {
  local layer

  for layer in "${!NEW_STAMP[@]}"; do
    echo "${NEW_STAMP[$layer]}" >"$STAMPS/$layer"
  done

  # Read by --post, which runs as a separate process in the tools tree
  printf '%s\n' "${!REBUILT[@]}" >"$STAMPS/.rebuilt"
}

load_stamps() {
  local file layer

  for file in "$STAMPS"/*; do
    if [[ -f "$file" ]]; then
      NEW_STAMP[${file##*/}]="$(cat "$file")"
    fi
  done

  # .rebuilt is a single empty line when nothing was rebuilt
  while read -r layer; do
    if [[ -n "$layer" ]]; then
      REBUILT[$layer]=1
    fi
  done <"$STAMPS/.rebuilt"
}

# systemctl preset-all silently skips unknown units, so a typo or renamed
# unit would leave a service off. systemd.preset(5) applies the first line for
# a unit in the lexicographic order of the file names, so an enable in a file
# that sorts before a disable of the same unit silently wins.
check_presets() {
  local tree="$1" name file action unit missing=() conflicts=()
  local -A first=()

  while IFS= read -r name; do
    file="$tree/usr/lib/systemd/system-preset/$name"
    [[ -f "$file" ]] || continue
    while read -r action unit _; do
      [[ "$action" == enable || "$action" == disable ]] || continue
      [[ "$unit" != *'*'* ]] || continue
      if [[ "$action" == enable ]]; then
        [[ -e "$tree/usr/lib/systemd/system/$unit" || -e "$tree/etc/systemd/system/$unit" ]] ||
          missing+=("$unit ($name)")
      fi
      if [[ -z "${first[$unit]:-}" ]]; then
        first[$unit]="$action $name"
      elif [[ "${first[$unit]%% *}" == enable && "$action" == disable ]]; then
        conflicts+=("$unit (enabled in ${first[$unit]#* }, disabled in $name)")
      fi
    done <"$file"
  done < <(find mkosi.images mkosi.profiles -name '*.preset' -printf '%f\n' | LC_ALL=C sort -u)

  ((${#missing[@]} == 0)) || die "units enabled in presets but missing in $tree: ${missing[*]}"
  ((${#conflicts[@]} == 0)) || die "enable sorts before disable, the disable has no effect in $tree: ${conflicts[*]}"
}

write_sbom() {
  local manifest="$1"
  scripts/sbom.py "$manifest" "$2" "$VERSION" >"${manifest%.manifest}.spdx.json"
}
