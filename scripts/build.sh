#!/usr/bin/env bash
# Runs build.sh in the builder container, from anywhere in the checkout.
# `build pkg ...` runs scripts/local-pkg.sh instead, as the user: cpb needs rootless podman.
# Tests run as the user too: VM windows and rootless podman.
#
# Usage:
#   build test iso <edition> [--openqa] [iso-test options | ISO path for openQA]
#   build test vm <edition> [vm-test options]
#   build test lima [lima-test options]       boot-check of root, then lima-test
#   build test distrobox [box name]           boot-check, then distrobox-test
#   build test oci                            oci-test
#   build virt iso|vm <edition> [virt options]   libvirt domain on qemu:///system, see scripts/virt.sh
#   build --test[=openqa] [build options] <output> ...   build, then test
#   build --tag[=<name>] oci|distrobox     build, then import into podman and docker,
#                                          default name localhost/garuda-<output>:latest

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=lib/env.sh
source lib/env.sh
load_env_local "$PWD"

die() {
  printf '\033[1;31m==> ERROR:\033[0m %s\n' "$*" >&2
  exit 1
}

run_test() {
  local output="${1:-}"
  [[ $# -gt 0 ]] && shift

  case "$output" in
    iso | vm)
      [[ $# -ge 1 && "$1" != --* ]] || die "build test $output needs an edition, for example: build test $output mokka"
      local edition="$1" openqa=false args=() arg
      shift

      for arg in "$@"; do
        if [[ "$arg" == --openqa && "$output" == iso ]]; then
          openqa=true
        else
          args+=("$arg")
        fi
      done

      if [[ "$openqa" == true ]]; then
        local distri="${OPENQA_DISTRI:-$PWD/../openqa-distri}"
        [[ -x "$distri/run-local.sh" ]] || die "no run-local.sh in $distri, set OPENQA_DISTRI to the openqa-distri checkout"
        IMAGE_BUILDER="$PWD" exec "$distri/run-local.sh" "$edition" "${args[@]}"
      fi

      exec bash "scripts/$output-test.sh" "$edition" "${args[@]}"
      ;;
    lima)
      bash scripts/boot-check.sh mkosi.output/root
      exec bash scripts/lima-test.sh "$@"
      ;;
    distrobox)
      bash scripts/boot-check.sh mkosi.output/garuda-distrobox
      exec bash scripts/distrobox-test.sh "$@"
      ;;
    oci)
      exec bash scripts/oci-test.sh "$@"
      ;;
    *)
      die "no test for '$output', use one of: iso, vm, lima, distrobox, oci"
      ;;
  esac
}

import_image() {
  local oci="mkosi.output/garuda-$1" tag="$2" imported=false

  if command -v podman >/dev/null; then
    skopeo copy "oci:$oci" "containers-storage:$tag"
    imported=true
  else
    echo "==> podman is not installed, skipping the podman import" >&2
  fi

  local docker
  if docker="$(command -v docker)" && sudo "$docker" info >/dev/null 2>&1; then
    # docker refuses zstd layers, and skopeo only recompresses into a layout, not into docker-daemon
    local gzip
    gzip="$(mktemp -d -p /var/tmp garuda-oci-gzip.XXXXXX)"
    skopeo copy --dest-compress-format gzip --dest-force-compress-format "oci:$oci" "oci:$gzip:latest"
    sudo "$(command -v skopeo)" copy "oci:$gzip:latest" "docker-daemon:$tag"
    rm -r -- "${gzip:?}"
    imported=true
  else
    echo "==> docker is not installed or not reachable, skipping the docker import" >&2
  fi

  [[ "$imported" == true ]] || die "neither podman nor docker is available for --tag"
  echo "==> Imported $tag"
}

case "${1:-}" in
  pkg)
    shift
    exec bash scripts/local-pkg.sh "$@"
    ;;
  test)
    shift
    run_test "$@"
    ;;
  virt)
    shift
    exec bash scripts/virt.sh "$@"
    ;;
esac

# --test and --tag are taken out here, build.sh does not know them
build_args=()
test_kind=""
tag=""
while [[ $# -gt 0 && "$1" == --* ]]; do
  case "$1" in
    --tag) tag=default ;;
    --tag=*)
      tag="${1#--tag=}"
      [[ -n "$tag" ]] || die "--tag= needs a name, or use --tag for localhost/garuda-<output>:latest"
      ;;
    --test) test_kind=default ;;
    --test=openqa) test_kind=openqa ;;
    --test=*) die "unknown test ${1#--test=}, use --test or --test=openqa" ;;
    --rebuild-layer)
      build_args+=("$1")
      if [[ $# -ge 2 ]]; then
        build_args+=("$2")
        shift
      fi
      ;;
    *) build_args+=("$1") ;;
  esac

  shift
done

output="${1:-}"
edition="${2:-}"
if [[ -n "$test_kind" ]]; then
  case "$output" in
    iso | vm | lima | distrobox | oci) ;;
    *) die "--test needs one of the outputs iso, vm, lima, distrobox, oci" ;;
  esac

  [[ "$test_kind" != openqa || "$output" == iso ]] || die "--test=openqa only tests an ISO"
fi

if [[ -n "$tag" ]]; then
  [[ "$output" == oci || "$output" == distrobox ]] || die "--tag needs the output oci or distrobox"
  [[ "$tag" != default ]] || tag="localhost/garuda-$output:latest"
fi

# SOURCE_DATE_EPOCH is not passed on: the Nix shell sets it to 1980
sudo --preserve-env=VERSION,ISO_COMPRESSION,BUILDER_UPDATE,SB_KEY,SB_CERT,SB_CA_CERT \
  ./build.sh --container "${build_args[@]}" "$@"

[[ -z "$tag" ]] || import_image "$output" "$tag"
[[ -n "$test_kind" ]] || exit 0
case "$output" in
  iso)
    if [[ "$test_kind" == openqa ]]; then
      run_test iso "$edition" --openqa
    fi
    run_test iso "$edition"
    ;;
  vm) run_test vm "$edition" ;;
  *) run_test "$output" ;;
esac
