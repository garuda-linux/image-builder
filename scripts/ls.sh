#!/usr/bin/env bash
# Usage: build ls
#   The current images in mkosi.output: version, age, size and the number of
#   older versions that build clean old would remove.

set -euo pipefail

root="$(git rev-parse --show-toplevel)"
out="$root/mkosi.output"

age() {
  local seconds=$(($(date +%s) - $(stat -c %Y "$1")))

  if ((seconds < 3600)); then
    echo "$((seconds / 60))m"
  elif ((seconds < 86400)); then
    echo "$((seconds / 3600))h"
  else
    echo "$((seconds / 86400))d"
  fi
}

# The name without its -YYYYMMDD version, the same for all versions of an image
unversioned() {
  [[ "$1" =~ ^(.*)-20[0-9]{6}(.*)$ ]] && echo "${BASH_REMATCH[1]}${BASH_REMATCH[2]}" || echo "$1"
}

older() {
  local target="$1" key file name count=0
  key="$(unversioned "$target")"

  for file in "$out"/garuda-*-20[0-9][0-9][0-9][0-9][0-9][0-9]*; do
    name="${file##*/}"
    [[ -f "$file" && "$name" != "$target" && "$name" != *.sha256 && "$name" != *.manifest && "$name" != *.spdx.json ]] || continue
    [[ "$(unversioned "$name")" == "$key" ]] && count=$((count + 1))
  done

  echo "$count"
}

printf '%-36s %-10s %5s %7s %5s\n' IMAGE VERSION AGE SIZE OLDER

for file in "$out"/garuda-*; do
  name="${file##*/}"
  version="-"

  if [[ -L "$file" ]]; then
    target="$(readlink "$file")"
    [[ "$target" =~ -(20[0-9]{6}) ]] && version="${BASH_REMATCH[1]}"
    printf '%-36s %-10s %5s %7s %5s\n' "$name" "$version" "$(age "$file")" "$(du -shL "$file" | cut -f1)" "$(older "$target")"
  elif [[ -d "$file" ]]; then
    [[ -f "$file.manifest" ]] && version="$(jq -r '.config.version // "-"' "$file.manifest")"
    printf '%-36s %-10s %5s %7s %5s\n' "$name" "$version" "$(age "$file")" "$(du -sh "$file" 2>/dev/null | cut -f1)" -
  fi
done
