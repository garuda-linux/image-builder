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

  # The signing files at their host paths, which check_secureboot made absolute
  if sb_enabled; then
    sb_is_uri && die "a pkcs11: SB_KEY needs the token, which the builder container has no access to"
    podman_args+=(
      --env SB_KEY="$SB_KEY" --env SB_CERT="$SB_CERT" --env SB_CA_CERT="$SB_CA_CERT"
      --volume "$SB_KEY:$SB_KEY:ro" --volume "$SB_CERT:$SB_CERT:ro"
    )
    if [[ -n "$SB_CA_CERT" ]]; then
      podman_args+=(--volume "$SB_CA_CERT:$SB_CA_CERT:ro")
    fi
  fi

  log "Running the build in $BUILDER_IMAGE"
  exec podman run "${podman_args[@]}" "$BUILDER_IMAGE" ./build.sh "$@"
}
