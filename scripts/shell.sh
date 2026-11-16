#!/usr/bin/env bash
# Usage: build shell base|root|desktop [-- command...]
#   Opens a root shell or runs a command in a layer tree with systemd-nspawn
#   --ephemeral: changes are gone on exit, the layer and its stamp stay valid.
#   desktop holds the edition built last.
#   Example: build shell desktop -- pacman -Qi plasma-desktop

set -euo pipefail

root="$(git rev-parse --show-toplevel)"
# shellcheck source=lib/log.sh
source "$root/lib/log.sh"

layer="${1:-}"
case "$layer" in
  base | root | desktop) shift ;;
  *) die "usage: build shell base|root|desktop [-- command...]" ;;
esac

[[ "${1:-}" != -- ]] || shift

tree="$root/mkosi.output/$layer"
[[ -d "$tree/usr" ]] || die "no $layer layer at $tree, run a build first"

release="$tree/usr/lib/garuda/garuda-release"
if [[ -f "$release" ]]; then
  log "$layer layer: $(grep -h '^EDITION=\|^TIMESTAMP=' "$release" | tr '\n' ' ')"
fi

# Empty: no socket family filter. A later nspawn allows only AF_INET, AF_INET6 and AF_UNIX by default
exec sudo "$(command -v systemd-nspawn)" --quiet --ephemeral --restrict-address-families= --directory="$tree" "$@"
