#!/usr/bin/env bash
# Usage: build which <package>
#   Where a package comes from: the mkosi configuration lines that name it, and
#   its version in the current images, also when only a dependency pulls it in.

set -euo pipefail

root="$(git rev-parse --show-toplevel)"
# shellcheck source=lib/log.sh
source "$root/lib/log.sh"

[[ $# -eq 1 && -n "$1" ]] || die "usage: build which <package>"
package="$1"

log "Named in the configuration"
cd "$root"

named=false
while IFS= read -r line; do
  content="${line#*:*:}"
  code="${content%%#*}"
  read -ra words <<<"${code//[=\"]/ }"

  for word in "${words[@]}"; do
    if [[ "$word" == "$package" ]]; then
      echo "    $line"
      named=true
      break
    fi
  done
done < <(grep -rnF --include='*.conf' -- "$package" mkosi.conf mkosi.conf.d mkosi.images mkosi.profiles 2>/dev/null)

[[ "$named" == true ]] || echo "    nowhere, only as a dependency or not at all"

log "In the current images"
found=false
for manifest in mkosi.output/*.manifest; do
  [[ "$manifest" =~ -20[0-9]{6} ]] && continue

  version="$(jq -r --arg name "$package" '.packages[] | select(.name == $name) | .version' "$manifest")"
  if [[ -n "$version" ]]; then
    printf '    %-40s %s\n' "$(basename "$manifest" .manifest)" "$version"
    found=true
  fi
done

[[ "$found" == true ]] || echo "    in none"
