#!/usr/bin/env bash
# Builds packages of a pkgbuilds repository with cpb into mkosi.packages/.
#
# Usage:
#   build pkg build [--pkgbuilds <dir>] <pkgbase>...
#   build pkg build [--pkgbuilds <dir>] --src <checkout> [--dir <name>] <pkgbase>
#     build from a local checkout, --dir sets the extracted source directory
#   build pkg list
#   build pkg rm <pkgname>...
#   build pkg clean
#
# <dir> defaults to $GARUDA_PKGBUILDS, else ../pkgbuilds.

set -euo pipefail

usage() {
  sed -n '2,/^$/p' "$0" | sed -e '/^$/d' -e 's/^# \{0,1\}//'
  exit "${1:-0}"
}

log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==> WARNING:\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[1;31m==> ERROR:\033[0m %s\n' "$*" >&2
  exit 1
}

root="$(git rev-parse --show-toplevel)"
packages_dir="$root/mkosi.packages"
arch="$(uname -m)"

readonly BASE_IMAGE="registry.gitlab.com/garuda-linux/tools/chaotic-manager/builder:latest"
readonly BUILDER_IMAGE="localhost/garuda-local-pkg-builder:latest"

readonly SUM_ARRAYS=(cksums md5sums sha1sums sha224sums sha256sums sha384sums sha512sums b2sums)

# Prints "<name> <pkgver>-<pkgrel>"
package_id() {
  local base="${1##*/}" name

  base="${base%.pkg.tar*}"
  name="${base%-*-*-*}"
  base="${base#"$name"-}"
  echo "$name ${base%-*}"
}

package_files() {
  local file

  for file in "$packages_dir"/*.pkg.tar*; do
    [[ -f "$file" && "$file" != *.sig ]] && echo "$file"
  done

  return 0
}

# Prints the number of removed files
remove_package() {
  local name="$1" file id count=0

  while read -r file; do
    read -r id _ < <(package_id "$file")
    if [[ "$id" == "$name" ]]; then
      rm -f "$file" "$file.sig"
      count=$((count + 1))
    fi
  done < <(package_files)
  echo "$count"
}

# The cpb builder plus garuda and chaotic-aur, with the keyring lib/chaotic.sh
# verified. The base image has no pacman master key, so --init first.
build_builder_image() {
  local ctx="$1" sandbox="$root/mkosi.sandbox"

  (
    cd "$root"
    SANDBOX="$sandbox"
    # shellcheck source=lib/chaotic.sh
    . lib/chaotic.sh
    fetch_chaotic false
  )

  mkdir -p "$ctx"
  cp "$sandbox"/usr/share/pacman/keyrings/chaotic* "$sandbox/etc/pacman.d/chaotic-mirrorlist" "$ctx/"
  cat >"$ctx/Containerfile" <<EOF
FROM $BASE_IMAGE
COPY chaotic.gpg chaotic-trusted chaotic-revoked /usr/share/pacman/keyrings/
COPY chaotic-mirrorlist /etc/pacman.d/chaotic-mirrorlist
RUN pacman-key --init && pacman-key --populate chaotic && \\
    sed -i 's|^\[core\]|[garuda]\nInclude = /etc/pacman.d/chaotic-mirrorlist\n\n[core]|' /etc/pacman.conf && \\
    printf '\n[chaotic-aur]\nInclude = /etc/pacman.d/chaotic-mirrorlist\n' >>/etc/pacman.conf && \\
    grep -q '^\[garuda\]' /etc/pacman.conf
EOF

  log "Building $BUILDER_IMAGE"
  podman build --quiet --tag "$BUILDER_IMAGE" "$ctx" >/dev/null || die "could not build $BUILDER_IMAGE"
}

run_cpb() {
  local work="$1" pkgbuilds="$2" cpb=(cpb)
  shift 2

  command -v cpb >/dev/null || cpb=(nix develop "$pkgbuilds" --command cpb)
  (cd "$work" && "${cpb[@]}" "$@")
}

# host/path in lower case, to compare a remote with source URLs
normalize_url() {
  local url="$1" host

  url="${url#git+}"
  url="${url%%#*}"
  url="${url%%\?*}"
  if [[ "$url" == *://* ]]; then
    url="${url#*://}"
    url="${url#*@}"
  else
    # user@host:path
    url="${url#*@}"
    host="${url%%:*}"
    [[ "$host" != */* ]] && url="$host/${url#*:}"
  fi
  url="${url%/}"
  url="${url%.git}"
  echo "${url,,}"
}

# Sets the global source and checksum arrays
load_sources() {
  local pkgbuild_dir="$1" decls

  decls="$(bash -c '
    set +eu
    cd "$1" || exit 1
    source ./PKGBUILD >/dev/null 2>&1
    shift
    for var in source "$@"; do
      declare -p "$var" 2>/dev/null
    done
    exit 0
  ' _ "$pkgbuild_dir" "${SUM_ARRAYS[@]}")" || die "could not read $pkgbuild_dir/PKGBUILD"

  unset source "${SUM_ARRAYS[@]}"
  eval "${decls//declare -a/declare -ga}"

  [[ -v source ]] || die "$pkgbuild_dir/PKGBUILD has no source array"
}

# A copy, because symlinks do not resolve in the builder container
stage_pkgbuild() {
  local pkgbuilds="$1" pkg="$2" stage="$3"

  mkdir -p "$stage"
  git -C "$pkgbuilds/$pkg" ls-files -z --cached --others --exclude-standard . |
    while IFS= read -r -d '' file; do
      [[ -e "$pkgbuilds/$pkg/$file" ]] && printf '%s\0' "$file"
    done |
    tar -C "$pkgbuilds/$pkg" --null -T - -cf - | tar -C "$stage" -xf -
}

# With .git, so pkgver() works
pack_checkout() {
  local checkout="$1" dir="$2" tarball="$3" dirty

  dirty="$(git -C "$checkout" status --porcelain)"
  if [[ -n "$dirty" ]]; then
    warn "uncommitted changes of $checkout go into the package:"
    printf '%s\n' "$dirty" | sed 's/^/    /' >&2
  fi

  {
    git -C "$checkout" ls-files -z --cached --others --exclude-standard |
      while IFS= read -r -d '' file; do
        [[ -e "$checkout/$file" || -L "$checkout/$file" ]] && printf '%s\0' "$file"
      done
    printf '.git\0'
  } | tar -C "$checkout" --null -T - --transform "s,^,$dir/,S" -czf "$tarball"
}

apply_local_source() {
  local stage="$1" checkout="$2" dir="$3" remote entry name url match=() i idx sum file

  remote="$(git -C "$checkout" remote get-url origin 2>/dev/null)" ||
    die "$checkout has no origin remote to match against the sources"
  remote="$(normalize_url "$remote")"

  load_sources "$stage"
  for i in "${!source[@]}"; do
    entry="${source[$i]}"
    url="${entry#*::}"
    [[ "$url" == *://* ]] || continue
    url="$(normalize_url "$url")"
    [[ "$url" == "$remote" || "$url" == "$remote"/* ]] && match+=("$i")
  done

  if ((${#match[@]} != 1)); then
    printf '  %s\n' "${source[@]}" >&2
    die "expected one source entry from $remote, found ${#match[@]}"
  fi

  idx="${match[0]}"
  entry="${source[$idx]}"
  name=""

  [[ "$entry" == *::* ]] && name="${entry%%::*}"
  url="${entry#*::}"
  url="${url%%#*}"
  url="${url%%\?*}"

  if [[ -z "$dir" ]]; then
    if [[ "$url" == git+* ]]; then
      dir="${name:-${url##*/}}"
      dir="${dir%.git}"
    else
      # GitLab archives extract to their name without extension
      dir="${name:-${url##*/}}"
      dir="${dir%.tar.*}"
      dir="${dir%.tgz}"
      dir="${dir%.zip}"
      [[ -n "$name" || "$url" == */-/archive/* ]] ||
        warn "guessed $dir as the directory of $entry, set --dir if the build cannot find it"
    fi
  fi

  file="$dir.local-src.tar.gz"
  log "Packing $checkout as $dir/ for source entry $idx: $entry"
  pack_checkout "$checkout" "$dir" "$stage/$file"

  source[idx]="$file"
  {
    printf '\n# local-pkg: source entry %s replaced by the checkout %s\n' "$idx" "$checkout"
    printf 'source=('
    printf ' %q' "${source[@]}"
    printf ' )\n'
    for sum in "${SUM_ARRAYS[@]}"; do
      local -n sums="$sum"
      if [[ -v sums ]]; then
        [[ -v "sums[idx]" ]] && sums[idx]=SKIP
        printf '%s=(' "$sum"
        printf ' %q' "${sums[@]}"
        printf ' )\n'
      fi
      unset -n sums
    done
  } >>"$stage/PKGBUILD"
}

# Own repo/: cpb skips repo-add for an existing file name, which would drop
# rebuilds of the same version
make_work() {
  local pkgbuilds="$1" work="$2" entry

  mkdir -p "$work/pkgbuilds" "$work/repo" "$pkgbuilds/cache" "$pkgbuilds/logs"
  [[ -d "$pkgbuilds/gpg" ]] || mkdir -m 0700 "$pkgbuilds/gpg"

  for entry in gpg cache logs; do
    ln -s "$pkgbuilds/$entry" "$work/$entry"
  done

  printf 'DOCKER_CONTAINER=%q\n' "$BUILDER_IMAGE" >"$work/config"
}

cmd_build() {
  local pkgbuilds="${GARUDA_PKGBUILDS:-$root/../pkgbuilds}" src="" dir="" pkgs=()

  while (($#)); do
    case "$1" in
      --pkgbuilds) pkgbuilds="${2:?--pkgbuilds needs a directory}" && shift ;;
      --src) src="${2:?--src needs a directory}" && shift ;;
      --dir) dir="${2:?--dir needs a name}" && shift ;;
      -h | --help) usage ;;
      -*) die "unknown option $1" ;;
      *) pkgs+=("$1") ;;
    esac
    shift
  done

  ((${#pkgs[@]} > 0)) || die "no package given"
  [[ -z "$dir" || -n "$src" ]] || die "--dir needs --src"
  [[ -z "$src" || ${#pkgs[@]} -eq 1 ]] || die "--src takes exactly one package"

  pkgbuilds="$(realpath "$pkgbuilds")"
  if [[ -n "$src" ]]; then
    src="$(realpath "$src")"
    git -C "$src" rev-parse --git-dir >/dev/null 2>&1 || die "$src is no git checkout"
  fi

  local pkg tmp work repo marker file name count copied
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/local-pkg.XXXXXX")"

  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT
  mkdir -p "$packages_dir"
  for pkg in "${pkgs[@]}"; do
    [[ -f "$pkgbuilds/$pkg/PKGBUILD" ]] || die "no PKGBUILD in $pkgbuilds/$pkg"
  done

  build_builder_image "$tmp/image"

  work="$tmp/work"
  make_work "$pkgbuilds" "$work"
  repo="$work/repo/builder/$arch"
  marker="$tmp/marker"

  for pkg in "${pkgs[@]}"; do
    stage_pkgbuild "$pkgbuilds" "$pkg" "$work/pkgbuilds/$pkg"
    [[ -z "$src" ]] || apply_local_source "$work/pkgbuilds/$pkg" "$src" "$dir"

    touch "$marker"
    log "Building $pkg with cpb"
    run_cpb "$work" "$pkgbuilds" build "$pkg" || die "cpb failed for $pkg, log: $pkgbuilds/logs/$pkg.log"

    mapfile -t copied < <(find "$repo" -maxdepth 1 -type f -name '*.pkg.tar*' ! -name '*.sig' -newer "$marker")
    ((${#copied[@]} > 0)) || die "cpb built no new package file of $pkg in $repo"

    for file in "${copied[@]}"; do
      read -r name _ < <(package_id "$file")
      count="$(remove_package "$name")"
      ((count == 0)) || log "Replacing the older $name in mkosi.packages/"
      cp "$file" "$packages_dir/"
      log "Added ${file##*/}"
    done
  done
}

cmd_list() {
  local file name version

  while read -r file; do
    read -r name version < <(package_id "$file")
    printf '%-40s %-30s %s\n' "$name" "$version" "${file##*/}"
  done < <(package_files)
}

cmd_rm() {
  local name count

  (($# > 0)) || die "no package given"
  for name in "$@"; do
    count="$(remove_package "$name")"
    ((count > 0)) || die "$name is not in mkosi.packages/"
    log "Removed $name"
  done
}

cmd_clean() {
  local file

  while read -r file; do
    rm -f "$file" "$file.sig"
    log "Removed ${file##*/}"
  done < <(package_files)
}

case "${1:-}" in
  build) shift && cmd_build "$@" ;;
  list) shift && cmd_list ;;
  rm) shift && cmd_rm "$@" ;;
  clean) shift && cmd_clean ;;
  -h | --help | help) usage ;;
  *) usage 1 >&2 ;;
esac
