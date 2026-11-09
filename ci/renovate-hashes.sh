#!/usr/bin/env bash
# Renovate postUpgradeTasks: download the bumped file and write its hash.
#   shim        SHIM_SHA512 in lib/secureboot.sh
#   nix-direnv  the direnvrc hash in .envrc
set -euo pipefail

die() {
  echo "renovate-hashes: $*" >&2
  exit 1
}

fetch() {
  curl -fsSL --proto '=https' --retry 3 "$1"
}

# sha256-<base64>, the integrity format of direnv's source_url
sri_sha256() {
  local hex bin="" i
  hex="$(sha256sum | cut -d' ' -f1)"
  for ((i = 0; i < ${#hex}; i += 2)); do bin+="\\x${hex:i:2}"; done
  printf 'sha256-%s' "$(printf '%b' "$bin" | base64 -w0)"
}

shim() {
  local file=lib/secureboot.sh hash

  # Reuses the URL format of the file
  eval "$(grep -E '^readonly SHIM_(VERSION|URL)=' "$file")"
  [[ -n "${SHIM_URL:-}" ]] || die "SHIM_URL not found in $file"

  hash="$(fetch "$SHIM_URL" | sha512sum | cut -d' ' -f1)"
  [[ "$hash" =~ ^[0-9a-f]{128}$ ]] || die "no sha512 for $SHIM_URL"

  sed -i -E "s/^(readonly SHIM_SHA512=\")[0-9a-f]+(\")/\1$hash\2/" "$file"
  grep -q "$hash" "$file" || die "SHIM_SHA512 not rewritten in $file"
}

nix_direnv() {
  local file=.envrc url hash
  url="$(grep -oE 'https://raw\.githubusercontent\.com/nix-community/nix-direnv/[^"]+/direnvrc' "$file")"
  [[ -n "$url" ]] || die "direnvrc URL not found in $file"

  hash="$(fetch "$url" | sri_sha256)"
  sed -i -E "s|(${url//./\\.}\" \")sha256-[A-Za-z0-9+/=]+(\")|\1$hash\2|" "$file"

  grep -qF "$hash" "$file" || die "direnvrc hash not rewritten in $file"
}

case "${1:-}" in
  shim) shim ;;
  nix-direnv) nix_direnv ;;
  *) die "usage: $0 shim|nix-direnv" ;;
esac
