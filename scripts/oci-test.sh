#!/usr/bin/env bash
# Usage: oci-test
#   Copies mkosi.output/garuda-oci into rootless podman and checks it in plain
#   containers without systemd, the way podman run and docker run start it.

set -euo pipefail

root="$(git rev-parse --show-toplevel)"
oci="$root/mkosi.output/garuda-oci"
image="localhost/garuda-oci:test"

if [[ ! -d "$oci" ]]; then
  echo "No image at $oci. Run: build oci" >&2
  exit 1
fi

skopeo copy "oci:$oci" "containers-storage:$image"

status=0
check() {
  local desc="$1" out
  shift
  if out="$(podman run --rm "$image" "$@" 2>&1)"; then
    printf '  \033[1;32mok\033[0m    %s\n' "$desc"
  else
    printf '  \033[1;31mfail\033[0m  %s\n' "$desc"
    printf '%s\n' "$out" | tail -5 | sed 's/^/          /'
    status=1
  fi
}

echo "Checking $image:"
check "Garuda os-release" grep -q '^ID=garuda$' /usr/lib/os-release
check "pacman keyring" sh -c 'gpg --homedir /etc/pacman.d/gnupg --list-secret-keys | grep -q "^sec"'
check "pacman syncs the repositories" pacman -Sy --noconfirm
check "garuda-update" garuda-update --noconfirm

exit "$status"
