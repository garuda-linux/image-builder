#!/usr/bin/env bash
# Build Garuda images with mkosi.
#
# Usage:
#   ./build.sh distrobox [mkosi args]
#   ./build.sh lima [mkosi args]
#   ./build.sh iso <edition> [mkosi args]
#
# Extra args go to mkosi as is, for example -E KERNEL=linux-lts.
# Options, before the output name:
#   --refresh-keys     download the chaotic keyring and mirrorlist again
#   --fresh            rebuild every layer and reinstall all packages
#                      (needed to pick up package updates)
#   --container        build inside the ci/Containerfile builder image
#                      (privileged podman, for hosts without Arch tools such as NixOS)
#   --rebuild-builder  build the builder image again (with --container)
#
# Environment:
#   VERSION          image version, default today as YYYYMMDD
#   ISO_COMPRESSION  fast (lz4, default) or max (zstd level 22, used by CI)
#
# Needs root (mkosi, loop devices, mounts).

set -euo pipefail

# errtrace passes the trap on to functions and subshells. The trap does not
# exit, so set -e still exits with the status of the failing command.
set -o errtrace
trap 'printf "\033[1;31m==> ERROR:\033[0m %s:%s: %s\n" "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

cd "$(dirname "$(readlink -f "$0")")"

readonly SANDBOX="mkosi.sandbox"
readonly OUTPUT_DIR="$PWD/mkosi.output" # absolute, so the paths stay valid in subshells that change directory
VERSION="${VERSION:-$(date +%Y%m%d)}"   # garuda-tools dist_timestamp

# Reproducible builds: all image timestamps are the last commit time.
# safe.directory: root runs git on a checkout owned by the user.
if [[ -z "${SOURCE_DATE_EPOCH:-}" ]]; then
  SOURCE_DATE_EPOCH="$(git -c safe.directory='*' log -1 --format=%ct 2>/dev/null || date -u -d "$VERSION" +%s)"
fi
export SOURCE_DATE_EPOCH
readonly VERSION SOURCE_DATE_EPOCH

log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() {
  printf '\033[1;31m==> ERROR:\033[0m %s\n' "$*" >&2
  exit 1
}

usage() {
  # The header comment must not contain an empty line
  sed -n '2,/^$/p' "$0" | sed -e '/^$/d' -e 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# shellcheck source=lib/chaotic.sh
source lib/chaotic.sh
# shellcheck source=lib/layers.sh
source lib/layers.sh
# shellcheck source=lib/lima.sh
source lib/lima.sh
# shellcheck source=lib/iso.sh
source lib/iso.sh
# shellcheck source=lib/container.sh
source lib/container.sh

# Post-build steps run in the mkosi tools tree, so they use the same tool
# versions as mkosi itself.
run_post() {
  local profile="$1"
  shift

  log "Post-build steps in the mkosi tools tree"
  mkosi --profile "$profile" sandbox -- env VERSION="$VERSION" ISO_COMPRESSION="$ISO_COMPRESSION" \
    SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" "$PWD/build.sh" --post "$@"
}

post_main() {
  load_stamps

  case "$1" in
    distrobox)
      check_presets "$OUTPUT_DIR/base"
      write_sbom "$OUTPUT_DIR/garuda-distrobox.manifest" garuda-distrobox
      ;;
    lima)
      post_lima
      write_sbom "$OUTPUT_DIR/garuda-lima.manifest" garuda-lima
      ;;
    iso)
      # live contains every layer below it, so this covers all presets
      check_presets "$OUTPUT_DIR/live"
      post_iso "$2"
      ;;
  esac
}

main() {
  local refresh=false container=false rebuild=false post=false
  local passthrough=()

  while [[ $# -gt 0 && "$1" == --* ]]; do
    case "$1" in
      --refresh-keys)
        refresh=true
        passthrough+=("$1")
        ;;
      --fresh)
        FORCE=(--force --force)
        passthrough+=("$1")
        ;;
      --container) container=true ;;
      --rebuild-builder) rebuild=true ;;
      --post) post=true ;; # internal, see run_post
      --help) usage ;;
      *) die "unknown option $1" ;;
    esac
    shift
  done

  [[ $# -ge 1 ]] || usage 1
  [[ $EUID -eq 0 ]] || die "run as root"

  if [[ "$post" == true ]]; then
    post_main "$@"
    return
  fi

  if [[ "$container" == true ]]; then
    run_in_container "$rebuild" "${passthrough[@]}" "$@"
  fi

  local output="$1"
  shift

  fetch_chaotic "$refresh"

  case "$output" in
    distrobox)
      prepare_layers "" base -- "$@"
      remove_output "$OUTPUT_DIR/garuda-distrobox"
      run_mkosi --profile distrobox "$@"
      write_stamps
      run_post distrobox distrobox
      ;;
    lima)
      prepare_layers "" base root -- "$@"
      remove_output "$OUTPUT_DIR/garuda-lima" "$OUTPUT_DIR/garuda-lima.raw"
      run_mkosi --profile lima "$@"
      write_stamps
      run_post lima lima
      ;;
    iso)
      [[ $# -ge 1 ]] || die "iso needs an edition, for example: ./build.sh iso mokka"
      local edition="$1"
      shift
      # mkosi splits --profile on commas, so "mokka," would build a broken ISO
      [[ -d "mkosi.images/desktop/mkosi.profiles/$edition" ]] ||
        die "unknown edition $edition, see scripts/editions.sh"

      local kernel_args=()
      mapfile -t kernel_args < <(edition_args "$edition" "$@")

      prepare_layers "$edition" base root desktop live mhwd live-initrd -- "${kernel_args[@]}" "$@"
      run_mkosi --profile iso --profile "$edition" "${kernel_args[@]}" "$@"
      write_stamps
      run_post iso iso "$edition"
      ;;
    *)
      usage 1
      ;;
  esac
}

main "$@"
