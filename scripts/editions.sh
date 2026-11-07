#!/usr/bin/env bash
# Prints the editions, one per line. The desktop profile directories are the only edition list.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

status=0
for dir in mkosi.images/desktop/mkosi.profiles/*/; do
  edition="$(basename "$dir")"
  if [[ ! -d "mkosi.images/live/mkosi.profiles/$edition" ]]; then
    echo "edition $edition has no mkosi.images/live/mkosi.profiles/$edition" >&2
    status=1
  fi
  echo "$edition"
done

exit "$status"
