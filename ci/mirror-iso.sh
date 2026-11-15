#!/usr/bin/env bash
# Usage: ci/mirror-iso.sh <edition>
#   Copies /publish/iso/<edition>/<kind>/ to R2 and SourceForge. See docs/ci.md#mirrors.

set -euo pipefail

edition="${1:?usage: ci/mirror-iso.sh <edition>}"
kind="${MIRROR_KIND:-release}"
root="${MIRROR_ROOT:-image-builder}"
src="${MIRROR_SOURCE:-/publish/iso}/$edition/$kind"
path="$root/$edition/$kind"
dry=()

[[ ${MIRROR_DRY_RUN:-} == 1 ]] && dry=(--dry-run)

[[ -d $src ]] || {
  echo "$src does not exist, nothing to mirror" >&2
  exit 1
}

r2() {
  echo "R2: $src -> r2:/mirror/iso/$path"

  rclone sync "${dry[@]}" --config "$R2_RCLONE_CONFIG" \
    --s3-upload-cutoff 5G --s3-chunk-size 4G --s3-no-check-bucket \
    --retries 3 --stats-one-line --stats 60s -v \
    "$src/" "r2:/mirror/iso/$path/"
}

sourceforge() {
  local key attempt known_hosts
  known_hosts="$(dirname "$0")/sourceforge-known-hosts"

  echo "SourceForge: $src -> frs.sourceforge.net:/home/frs/project/garuda-linux/$path"

  key="$(mktemp)"
  install -m 600 "$SOURCEFORGE_SSH_KEY" "$key"

  for attempt in 1 2 3; do
    if rsync "${dry[@]}" -rt --delete --mkpath --chmod=D755,F644 \
      -e "ssh -i $key -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$known_hosts" \
      "$src/" "garuda-team@frs.sourceforge.net:/home/frs/project/garuda-linux/$path/"; then
      rm -f "$key"
      return 0
    fi

    [[ $attempt == 3 ]] || {
      echo "SourceForge upload failed (attempt $attempt of 3), retrying in 30 seconds"
      sleep 30
    }
  done

  rm -f "$key"
  return 1
}

status=0

if [[ -n ${R2_RCLONE_CONFIG:-} ]]; then
  r2 || status=1
else
  echo "R2_RCLONE_CONFIG is not set, skipping R2"
fi

if [[ -n ${SOURCEFORGE_SSH_KEY:-} ]]; then
  sourceforge || status=1
else
  echo "SOURCEFORGE_SSH_KEY is not set, skipping SourceForge"
fi

exit "$status"
