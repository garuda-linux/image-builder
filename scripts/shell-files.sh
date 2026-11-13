#!/usr/bin/env bash
# The shell scripts of the repository, for scripts/lint.sh and the shfmt
# pre-commit hook in flake.nix. Prints one path per line.
#   shell-files.sh --exec <command> [<argument>...]
# runs <command> with the paths appended instead.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

out="$(git ls-files '*.sh' '*.chroot' \
  'mkosi.images/live-initrd/mkosi.extra/usr/bin/*' \
  'mkosi.images/live-initrd/mkosi.extra/usr/lib/systemd/system-generators/*' \
  'mkosi.images/live/mkosi.extra/usr/bin/*' \
  'mkosi.images/*/mkosi.extra/usr/lib/garuda/*')"

if [[ "${1:-}" == --exec ]]; then
  shift
  mapfile -t files <<<"$out"
  exec "$@" "${files[@]}"
fi

echo "$out"
