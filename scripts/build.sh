#!/usr/bin/env bash
# Runs build.sh in the builder container, from anywhere in the checkout.
# `build pkg ...` runs scripts/local-pkg.sh instead, as the user: cpb needs rootless podman.
# Tests run as the user too: VM windows and rootless podman.
#
# Usage:
#   build test iso [edition] [--openqa] [iso-test options | ISO path for openQA]
#   build test vm [edition] [vm-test options]
#   build test lima [lima-test options]       boot-check of root, then lima-test
#   build test distrobox [box name]           boot-check, then distrobox-test
#   build test oci                            oci-test
#   build virt iso|vm [edition] [virt options]   libvirt domain on qemu:///system, see scripts/virt.sh
#   build virt list | rm <domain>...|--all
#   build ls                                  the current images, see scripts/ls.sh
#   build journal iso|vm|virt [domain] [journalctl options]
#   build shell base|root|desktop [-- command...]
#   build which <package>
#   build diff <edition> [old] [new]
#   build flash <edition> <device> [--version=<YYYYMMDD>] [--yes]
#   build verify <edition> [--version=<YYYYMMDD>]
#   build --test[=<opt>,...] [build options] <output> ...   build, then test, each item is
#                                          an iso-test, vm-test or lima-test option without --
#   build --openqa [build options] iso <edition>   build, then the openQA run
#   build --virt[=<opt>,...] [build options] iso|vm <edition>   build, then build virt,
#                                          each item is a virt option without --, e.g. open,ram=8G
#   build --tag[=<name>] oci|distrobox     build, then import into podman and docker,
#                                          default name localhost/garuda-<output>:latest
#   build iso|vm <edition>,<edition>... | all   one build per edition, a summary at the end
#   build --notify ...                     desktop notification when a build or test ends,
#                                          also with NOTIFY=1
#   The edition of build test and build virt defaults to EDITION.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# shellcheck source=lib/env.sh
source lib/env.sh
load_env_local "$PWD"

# shellcheck source=lib/log.sh
source lib/log.sh
# shellcheck source=lib/args.sh
source lib/args.sh

comma_options() {
  local items=()
  IFS=, read -ra items <<<"$1"
  printf -- '--%s\n' "${items[@]}"
}

notify_end() {
  local status=$? summary="${NOTIFY_SUMMARY:-}"
  [[ "${NOTIFY:-0}" == 1 ]] || return "$status"

  if ! command -v notify-send >/dev/null; then
    warn "--notify needs notify-send (libnotify)"
    return "$status"
  fi

  local title="build $COMMAND finished"
  ((status == 0)) || title="build $COMMAND failed (exit $status)"

  notify-send --app-name="Garuda image-builder" --icon=system-run "$title" \
    "after $((SECONDS / 60))m $((SECONDS % 60))s${summary:+
$summary}" || true

  return "$status"
}

run_test() {
  local output="${1:-}"
  [[ $# -gt 0 ]] && shift

  case "$output" in
    iso | vm)
      local edition="${EDITION:-}" openqa=false args=() arg

      if [[ $# -ge 1 && "$1" != --* ]]; then
        edition="$1"
        shift
      fi

      check_edition "$PWD" "$edition"

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
        IMAGE_BUILDER="$PWD" "$distri/run-local.sh" "$edition" "${args[@]}"
        return
      fi

      bash "scripts/$output-test.sh" "$edition" "${args[@]}"
      ;;
    lima)
      bash scripts/boot-check.sh mkosi.output/root
      bash scripts/lima-test.sh "$@"
      ;;
    distrobox)
      bash scripts/boot-check.sh mkosi.output/garuda-distrobox
      bash scripts/distrobox-test.sh "$@"
      ;;
    oci)
      bash scripts/oci-test.sh "$@"
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
    warn "podman is not installed, skipping the podman import"
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
    warn "docker is not installed or not reachable, skipping the docker import"
  fi

  [[ "$imported" == true ]] || die "neither podman nor docker is available for --tag"
  log "Imported $tag"
}

# build <output> <edition>,<edition>... or all: one build.sh run per edition,
# continues after a failure
build_editions() {
  local output="$1" list="$2" edition start status results=() failed=0 editions=()
  shift 2

  if [[ "$list" == all ]]; then
    mapfile -t editions < <(bash scripts/editions.sh)
  else
    IFS=, read -ra editions <<<"$list"
  fi

  for edition in "${editions[@]}"; do
    check_edition "$PWD" "$edition"
  done

  for edition in "${editions[@]}"; do
    log "Building $output $edition (${#results[@]} of ${#editions[@]} done)"
    start=$SECONDS

    status=0
    sudo --preserve-env=VERSION,ISO_COMPRESSION,BUILDER_UPDATE,SB_KEY,SB_CERT,SB_CA_CERT \
      ./build.sh --container "${build_args[@]}" "$output" "$edition" "$@" || status=$?

    ((status == 0)) || failed=$((failed + 1))
    results+=("$(printf '%-20s %-6s %dm %02ds' "$edition" "$( ((status == 0)) && echo ok || echo FAILED)" \
      $(((SECONDS - start) / 60)) $(((SECONDS - start) % 60)))")
  done

  log "Summary: $((${#editions[@]} - failed)) of ${#editions[@]} built"
  printf '    %s\n' "${results[@]}"

  NOTIFY_SUMMARY="$(printf '%s\n' "${results[@]}")"
  ((failed == 0))
}

COMMAND="$*"
if [[ "${1:-}" == --notify ]]; then
  NOTIFY=1
  shift
  COMMAND="$*"
fi

trap notify_end EXIT

case "${1:-}" in
  pkg)
    shift
    exec bash scripts/local-pkg.sh "$@"
    ;;
  test)
    shift
    run_test "$@"
    exit
    ;;
  virt | ls | journal | shell | which | diff | flash | verify)
    verb="$1"
    shift
    exec bash "scripts/$verb.sh" "$@"
    ;;
esac

# --test, --openqa, --tag, --virt and --notify are taken out here, build.sh does not know them
build_args=()
test=false
test_args=()
openqa=false
tag=""
virt=false
virt_args=()
explain=false
while [[ $# -gt 0 && "$1" == --* ]]; do
  case "$1" in
    --tag) tag=default ;;
    --tag=*)
      tag="${1#--tag=}"
      [[ -n "$tag" ]] || die "--tag= needs a name, or use --tag for localhost/garuda-<output>:latest"
      ;;
    --test) test=true ;;
    --test=*)
      test=true
      [[ -n "${1#--test=}" ]] || die "--test= needs options, for example --test=cdrom,ram=8G, or use --test"
      mapfile -t test_args < <(comma_options "${1#--test=}")
      ;;
    --openqa) openqa=true ;;
    --virt) virt=true ;;
    --virt=*)
      virt=true
      [[ -n "${1#--virt=}" ]] || die "--virt= needs options, for example --virt=open,ram=8G, or use --virt"
      mapfile -t virt_args < <(comma_options "${1#--virt=}")
      ;;
    --notify) NOTIFY=1 ;;
    --explain)
      explain=true
      build_args+=("$1")
      ;;
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

if [[ ("$output" == iso || "$output" == vm) && ("$edition" == *,* || "$edition" == all) ]]; then
  [[ "$test" == false && "$openqa" == false && "$virt" == false ]] ||
    die "--test, --openqa and --virt need a single edition"

  build_editions "$output" "$edition" "${@:3}"
  exit
fi

if [[ "$test" == true ]]; then
  case "$output" in
    iso | vm | lima) ;;
    distrobox | oci) ((${#test_args[@]} == 0)) || die "--test=<options> is for iso, vm and lima, use --test" ;;
    *) die "--test needs one of the outputs iso, vm, lima, distrobox, oci" ;;
  esac
fi

[[ "$openqa" == false || "$output" == iso ]] || die "--openqa only tests an ISO"
[[ "$openqa" == false || "$test" == false ]] || die "--openqa and --test cannot be combined"
[[ "$virt" == false || "$output" == iso || "$output" == vm ]] || die "--virt needs the output iso or vm"

if [[ -n "$tag" ]]; then
  [[ "$output" == oci || "$output" == distrobox ]] || die "--tag needs the output oci or distrobox"
  [[ "$tag" != default ]] || tag="localhost/garuda-$output:latest"
fi

# SOURCE_DATE_EPOCH is not passed on: the Nix shell sets it to 1980
sudo --preserve-env=VERSION,ISO_COMPRESSION,BUILDER_UPDATE,SB_KEY,SB_CERT,SB_CA_CERT \
  ./build.sh --container "${build_args[@]}" "$@"

# --explain builds nothing
[[ "$explain" == false ]] || exit 0

[[ -z "$tag" ]] || import_image "$output" "$tag"

# Before the tests, which block until their VM is closed
[[ "$virt" == false ]] || bash scripts/virt.sh "$output" "$edition" "${virt_args[@]}"
[[ "$openqa" == false ]] || run_test iso "$edition" --openqa
[[ "$test" == true ]] || exit 0

case "$output" in
  iso | vm) run_test "$output" "$edition" "${test_args[@]}" ;;
  *) run_test "$output" "${test_args[@]}" ;;
esac
