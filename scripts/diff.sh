#!/usr/bin/env bash
# Usage: build diff <edition> [old] [new]
#   The package changes between two ISO versions (YYYYMMDD) of an edition,
#   default the two newest. Lists the versions when there are fewer than two.

set -euo pipefail

root="$(git rev-parse --show-toplevel)"
# shellcheck source=lib/env.sh
source "$root/lib/env.sh"
load_env_local "$root"

# shellcheck source=lib/log.sh
source "$root/lib/log.sh"
# shellcheck source=lib/args.sh
source "$root/lib/args.sh"
# shellcheck source=lib/images.sh
source "$root/lib/images.sh"

edition="${1:-${EDITION:-}}"
check_edition "$root" "$edition"

versions=()
mapfile -t versions < <(iso_versions "$root" "$edition")
((${#versions[@]} >= 2 || $# >= 3)) ||
  die "build diff needs two ISO versions of $edition, found: ${versions[*]:-none}"

old="${2:-${versions[-2]}}"
new="${3:-${versions[-1]}}"

manifest() {
  local matches=()
  mapfile -t matches < <(compgen -G "$root/mkosi.output/garuda-$edition-linux*-$1.iso.manifest")
  ((${#matches[@]} == 1)) || die "no manifest of $edition for version $1, versions: ${versions[*]}"

  echo "${matches[0]}"
}

old_manifest="$(manifest "$old")"
new_manifest="$(manifest "$new")"

log "$edition: $old -> $new"
exec python3 -I "$root/scripts/manifest_diff.py" "$old_manifest" "$new_manifest"
