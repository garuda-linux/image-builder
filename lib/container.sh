# shellcheck shell=bash

readonly BUILDER_IMAGE="localhost/garuda-image-builder:latest"

# /dev is mounted so the loop partitions of the Lima disk appear in the container.
run_in_container() {
  local rebuild="$1"
  shift

  # podman copies image layers through TMPDIR, by default /var/tmp, which is
  # often too small. mkosi.cache is on the disk the build needs anyway.
  export TMPDIR="$PWD/mkosi.cache/tmp"
  mkdir -p "$TMPDIR"

  if [[ "$rebuild" == true ]] || ! podman image exists "$BUILDER_IMAGE"; then
    log "Building the builder image $BUILDER_IMAGE"
    podman build -t "$BUILDER_IMAGE" -f ci/Containerfile ci
  fi

  local podman_args=(
    --rm
    --privileged
    --volume "$PWD:/build"
    --volume /dev:/dev
    --env VERSION="$VERSION"
    --env SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH"
    --env ISO_COMPRESSION="$ISO_COMPRESSION"
    --workdir /build
  )

  log "Running the build in $BUILDER_IMAGE"
  exec podman run "${podman_args[@]}" "$BUILDER_IMAGE" ./build.sh "$@"
}
