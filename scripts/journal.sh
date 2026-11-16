#!/usr/bin/env bash
# Usage: build journal iso|vm|virt [domain] [journalctl options]
#   Reads the guest journal of the last iso-test or vm-test run, or of a
#   libvirt domain started with build virt --attach (default: the newest).
#   Example: build journal vm -b -u pacman-init.service

set -euo pipefail

root="$(git rev-parse --show-toplevel)"
# shellcheck source=lib/log.sh
source "$root/lib/log.sh"

kind="${1:-}"
[[ $# -gt 0 ]] && shift

case "$kind" in
  iso | vm) dir="$root/mkosi.cache/qemu/$kind-test-journal" ;;
  virt)
    state="${XDG_STATE_HOME:-$HOME/.local/state}/garuda-libvirt"

    if [[ $# -ge 1 && "$1" != -* ]]; then
      dir="$state/$1"
      shift
    else
      dir="$(find "$state" -mindepth 2 -maxdepth 2 -name '*.journal' -printf '%T@ %h\n' 2>/dev/null | sort -rn | head -n 1 | cut -d' ' -f2-)"
      [[ -n "$dir" ]] || die "no libvirt journal in $state, start the domain with build virt ... --attach"
    fi
    ;;
  *) die "usage: build journal iso|vm|virt [domain] [journalctl options]" ;;
esac

compgen -G "$dir/*.journal" >/dev/null || die "no journal in $dir"

log "Journal: $dir"
exec journalctl --directory="$dir" "$@"
