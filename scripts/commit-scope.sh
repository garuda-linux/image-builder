#!/usr/bin/env bash
# Checks that a commit message has a scope from the allowed list.
#
# Usage:
#   scripts/commit-scope.sh <message file>   commit-msg hook (prek, see flake.nix)
#   scripts/commit-scope.sh --ci             the commits of a CI pipeline
#
# Allowed scopes: an output (distrobox, oci, lima, vm, uki, iso), an edition from
# scripts/editions.sh, a layer, or an area of the build.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

outputs="distrobox oci lima vm uki iso"
layers="layers base root desktop live drivers live-initrd"
areas="build secureboot container installer openqa scripts ci docs deps"
editions="$(scripts/editions.sh | tr '\n' ' ')"
allowed=" $outputs $layers $areas $editions "

# check <subject> <where>: prints the problem and fails
check() {
  local subject="$1" where="$2" scopes scope

  # fixup!, squash! and amend! commits carry the subject they change
  while [[ "$subject" =~ ^(fixup|squash|amend)!\ (.*)$ ]]; do
    subject="${BASH_REMATCH[2]}"
  done

  if [[ "$subject" =~ ^(bump|ci):\  || "$subject" =~ ^Merge\  || "$subject" =~ ^Revert\ \" ]]; then
    return 0
  fi

  if [[ ! "$subject" =~ ^[a-z]+\(([^\)]+)\)!?:\  ]]; then
    printf '%s: no scope in "%s"\n' "$where" "$subject" >&2
    return 1
  fi

  IFS=, read -ra scopes <<<"${BASH_REMATCH[1]}"
  for scope in "${scopes[@]}"; do
    scope="${scope# }"
    if [[ "$allowed" != *" $scope "* ]]; then
      printf '%s: scope "%s" is not allowed in "%s"\n' "$where" "$scope" "$subject" >&2
      return 1
    fi
  done
}

hint() {
  printf 'Allowed scopes:\n  outputs:  %s\n  editions: %s\n  layers:   %s\n  areas:    %s\n' \
    "$outputs" "$editions" "$layers" "$areas" >&2
}

if [[ "${1:-}" == --ci ]]; then
  # Tags and the first push of a branch (zero before-SHA) check the last
  # commit only. Commits outside the shallow clone cannot be checked.
  before="${CI_COMMIT_BEFORE_SHA:-}"
  head="${CI_COMMIT_SHA:-HEAD}"
  if [[ -n "${CI_COMMIT_TAG:-}" || -z "$before" || "$before" =~ ^0+$ ]] ||
    ! git cat-file -e "$before^{commit}" 2>/dev/null; then
    range="$head -1"
  else
    range="$before..$head"
  fi

  status=0
  # shellcheck disable=SC2086 # range is one or two arguments
  while IFS=$'\t' read -r sha subject; do
    check "$subject" "${sha:0:12}" || status=1
  done < <(git log --no-merges --format='%H%x09%s' $range)
  [[ "$status" -eq 0 ]] || hint
  exit "$status"
fi

[[ $# -eq 1 && -f "$1" ]] || {
  echo "usage: scripts/commit-scope.sh <message file> | --ci" >&2
  exit 2
}

# The first line that is not a comment, as git strips comments later
subject="$(grep -v '^#' "$1" | head -n1)"
check "$subject" "commit message" || {
  hint
  exit 1
}
