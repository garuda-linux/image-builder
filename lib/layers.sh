# shellcheck shell=bash
# mkosi 27 turns Incremental= off for images on BaseTrees=, so only base gets
# a package snapshot. Each layer gets a stamp instead: a hash of its inputs and
# the stamp of the layer below. Unchanged layers are reused across editions,
# unless a package in them has an update in the repositories.
readonly STAMPS="$OUTPUT_DIR/.stamps"

# Files of the package check. A dot directory, so load_stamps skips it.
readonly CHECK_DIR="$STAMPS/.check"

# Quoted keys: shfmt would turn an unquoted live-initrd into arithmetic
declare -rA LAYER_BELOW=(["base"]="" ["root"]=base ["desktop"]=root ["live"]=desktop ["mhwd"]=desktop ["live-initrd"]=root)

declare -A NEW_STAMP=() REBUILT=()

# --fresh passes --force twice, which also drops the package snapshot of the
# base layer.
FORCE=()

# Layers named with --rebuild-layer
declare -A FORCED=()

# mkosi arguments of the output, set by main: profiles, kernel and extra args
MKOSI_ARGS=()

# Set by check_packages: cache path prefix per image, result per layer database
declare -A CACHE_PREFIX=() PACKAGES=()

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

  log "mkosi ${MKOSI_ARGS[*]} (version $VERSION)"
  mkosi --image-version="$VERSION" "${env_args[@]}" "${MKOSI_ARGS[@]}" "${FORCE[@]}" build
}

# Contents, and the path, mode, type and link target of every entry: a chmod
# or a changed symlink in mkosi.extra must change the stamp as well. No mtime,
# a checkout has arbitrary ones.
hash_files() {
  local path existing=()

  for path in "$@"; do
    [[ -e "$path" ]] && existing+=("$path")
  done

  if ((${#existing[@]} == 0)); then
    echo none
    return
  fi

  {
    find "${existing[@]}" -printf '%p %m %y %l\n' | LC_ALL=C sort
    find "${existing[@]}" -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum
  } | sha256sum | cut -d' ' -f1
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

# The one kernel of a tree: prints its version and pkgbase
tree_kernel() {
  local tree="$1" kdirs
  kdirs=("$tree"/usr/lib/modules/*/)
  [[ ${#kdirs[@]} -eq 1 && -d "${kdirs[0]}" ]] || die "expected exactly one kernel in $tree"
  basename "${kdirs[0]}"
  cat "${kdirs[0]}pkgbase"
}

# The cache tree is the only database of live-initrd, its output is a cpio archive
layer_db() {
  local layer="$1" kind="$2"

  case "$kind" in
    output) echo "$(layer_output "$layer")/var/lib/pacman" ;;
    cache) echo "${CACHE_PREFIX[$layer]:-/nonexistent}.cache/var/lib/pacman" ;;
  esac
}

# Runs in the tools tree (build.sh --packages). Syncs into mkosi's metadata
# cache, because mkosi 27 syncs only when a cache is stale. Output lines:
#   prefix <image> <mkosi cache path prefix>
#   check <layer> <output|cache> clean|missing|unknown|<package>...
packages_main() {
  local summary="$1" image prefix main conf layer kind db dir out
  shift

  # The default CacheKey is &d~&r~&a~&I
  while read -r image prefix; do
    echo "prefix $image $prefix"
    CACHE_PREFIX[$image]="$prefix"
  done < <(jq -r '.Images[] | . as $c | $c.Image + " " + $c.CacheDirectory + "/" + ($c.CacheKey |
    gsub("&d"; $c.Distribution) | gsub("&r"; $c.Release) | gsub("&a"; $c.Architecture) | gsub("&I"; $c.Image))' \
    "$summary")

  main="${CACHE_PREFIX[main]:-}"
  [[ -n "$main" ]] || die "no main image in $summary"
  [[ "$main" != *'&'* ]] || die "unsupported specifier in the mkosi CacheKey: $main"

  # First build: mkosi has no keyring yet, and no layer can be reused anyway
  if ! compgen -G "$main.keyring.cache/*" >/dev/null; then
    for layer in "$@"; do
      echo "check $layer output unknown"
      echo "check $layer cache unknown"
    done
    return
  fi

  # The sandbox tree is not mounted here, so its files are named by path
  conf="$CHECK_DIR/pacman.conf"
  sed "s|/etc/pacman.d/|$PWD/$SANDBOX/etc/pacman.d/|" "$SANDBOX/etc/pacman.conf" >"$conf"
  mkdir -p "$main.metadata.cache/lib/pacman/local"
  log "Syncing the repository databases" >&2
  pacman -Sy --noconfirm --config "$conf" --dbpath "$main.metadata.cache/lib/pacman" \
    --gpgdir "$main.keyring.cache" --logfile /dev/null >&2 ||
    die "could not sync the repository databases, needed to check the reused layers for package updates"

  for layer in "$@"; do
    for kind in output cache; do
      db="$(layer_db "$layer" "$kind")"
      if [[ ! -d "$db/local" ]]; then
        echo "check $layer $kind missing"
        continue
      fi

      # pacman reads local and sync from one --dbpath
      dir="$CHECK_DIR/db/$layer-$kind"
      mkdir -p "$dir"
      ln -sfn "$db/local" "$dir/local"
      ln -sfn "$main.metadata.cache/lib/pacman/sync" "$dir/sync"

      # -Qu exits 1 both without updates and on errors, stderr tells them apart
      if out="$(pacman -Qqu --config "$conf" --dbpath "$dir" 2>"$dir.err")"; then
        echo "check $layer $kind ${out//$'\n'/ }"
      elif ! grep -q '^error:' "$dir.err"; then
        echo "check $layer $kind clean"
      else
        cat "$dir.err" >&2
        echo "check $layer $kind unknown"
      fi
    done
  done
}

check_packages() {
  local env_args=() layer word kind line result

  for layer in "$@"; do
    env_args+=(--environment="$(build_var "$layer")=1")
  done

  mkdir -p "$CHECK_DIR"
  mkosi "${env_args[@]}" "${MKOSI_ARGS[@]}" --json summary >"$CHECK_DIR/summary.json"

  # In a variable, so set -e stops the build when the sync fails
  result="$(mkosi "${MKOSI_ARGS[@]}" sandbox -- "$PWD/build.sh" --packages "$CHECK_DIR/summary.json" "$@")"

  while read -r word layer kind line; do
    case "$word" in
      prefix) CACHE_PREFIX[$layer]="$kind" ;;
      check) PACKAGES["$layer-$kind"]="$line" ;;
    esac
  done <<<"$result"
}

# Empty when the packages are current
packages_reason() {
  local layer="$1" result updates=()

  result="${PACKAGES["$layer-output"]:-unknown}"
  [[ "$result" == missing ]] && result="${PACKAGES["$layer-cache"]:-unknown}"

  case "$result" in
    clean) ;;
    missing | unknown) echo "its packages could not be checked" ;;
    *)
      read -ra updates <<<"$result"
      echo "${#updates[@]} packages with updates (${updates[*]:0:5}${updates[5]:+ ...})"
      ;;
  esac
}

# mkosi reuses the cache of base and live-initrd, old packages included, while
# their config is unchanged
drop_mkosi_cache() {
  local layer="$1" prefix="${CACHE_PREFIX[$1]:-}"

  [[ -n "$prefix" && -e "$prefix.cache" ]] || return 0
  if [[ -n "${FORCED[$layer]:-}" || "${PACKAGES["$layer-cache"]:-unknown}" != clean ]]; then
    log "Dropping the mkosi cache of the $layer layer"
    remove_output "$prefix.cache" "$prefix.build.cache" "$prefix.manifest"
  fi
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

  for layer in "${!FORCED[@]}"; do
    [[ " ${layers[*]} " == *" $layer "* ]] || die "--rebuild-layer $layer: this output has the layers ${layers[*]}"
  done

  mkdir -p "$STAMPS"
  # --fresh rebuilds everything, and mkosi -ff syncs the databases itself
  ((${#FORCE[@]} > 0)) || check_packages "${layers[@]}"

  local reason parts
  for layer in "${layers[@]}"; do
    below="${LAYER_BELOW[$layer]}"
    parts=("$global" "${below:+${NEW_STAMP[$below]}}" "$(layer_files_hash "$layer" "$edition")")
    # The Secure Boot cert in the root layer, see lib/secureboot.sh
    if [[ "$layer" == root && -n "$SB_CERT" ]]; then
      parts+=("$(sb_stamp)")
    fi
    stamp="$(printf '%s\n' "${parts[@]}" | sha256sum | cut -d' ' -f1)"
    NEW_STAMP[$layer]="$stamp"

    if ((${#FORCE[@]} > 0)); then
      reason="--fresh"
    elif [[ -n "${FORCED[$layer]:-}" ]]; then
      reason="--rebuild-layer"
    elif [[ ! -e "$(layer_output "$layer")" ]]; then
      reason="no output yet"
    elif [[ -n "$below" && -n "${REBUILT[$below]:-}" ]]; then
      reason="the $below layer is rebuilt"
    elif [[ "$(cat "$STAMPS/$layer" 2>/dev/null)" != "$stamp" ]]; then
      reason="its inputs changed"
    else
      reason="$(packages_reason "$layer")"
    fi

    if [[ -z "$reason" ]]; then
      log "Reusing the $layer layer"
    else
      log "Rebuilding the $layer layer: $reason"
      REBUILT[$layer]=1
      rm -f "$STAMPS/$layer"
      remove_output "$OUTPUT_DIR/$layer" "$(layer_output "$layer")"
      ((${#FORCE[@]} > 0)) || drop_mkosi_cache "$layer"
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

  [[ -f "$STAMPS/.rebuilt" ]] || die "$STAMPS/.rebuilt not found: --post needs a finished build.sh run"

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
