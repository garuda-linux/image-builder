#!/usr/bin/env bash
# Usage: distrobox-test [box name]

set -euo pipefail

root="$(git rev-parse --show-toplevel)"
oci="$root/mkosi.output/garuda-distrobox"
image="localhost/garuda-distrobox:test"
box="${1:-garuda-test}"

if [[ ! -d "$oci" ]]; then
  echo "No image at $oci. Run: build distrobox" >&2
  exit 1
fi

skopeo copy "oci:$oci" "containers-storage:$image"

distrobox rm --force "$box" >/dev/null 2>&1 || true
# The image ships no pacman keyring. distrobox-init needs one for its first pacman run.
distrobox create --yes --image "$image" --name "$box" --init \
  --pre-init-hooks "pacman-key --init && pacman-key --populate"

# Output stays visible because most problems appear in the distrobox setup
echo "Starting $box (first enter runs the distrobox setup):"
if ! distrobox enter --no-workdir "$box" -- true; then
  echo "distrobox enter failed. Container log:" >&2
  podman logs --tail 50 "$box" >&2 || true
  exit 1
fi

status=0
check() {
  local desc="$1" out
  shift
  if out="$(distrobox enter --no-workdir "$box" -- "$@" 2>&1)"; then
    printf '  \033[1;32mok\033[0m    %s\n' "$desc"
  else
    printf '  \033[1;31mfail\033[0m  %s\n' "$desc"
    printf '%s\n' "$out" | tail -5 | sed 's/^/          /'
    status=1
  fi
}

echo "Checking $box:"
check "garuda-hooks installed" pacman -Q garuda-hooks
check "sudo without password" sudo -n true
# Same bar as boot-check: degraded means a failed unit
# shellcheck disable=SC2016 # expanded by the shell inside the box
check "systemd runs as init" sh -c 'state="$(systemctl is-system-running --wait)"
  [ "$state" = running ] && exit 0
  echo "systemd is $state, failed units:"
  systemctl --failed --plain --no-legend
  exit 1'
check "Garuda os-release" grep -q '^ID=garuda$' /usr/lib/os-release
# Only a keyring made inside the box has a secret master key
check "own pacman keyring" sh -c 'sudo -n gpg --homedir /etc/pacman.d/gnupg --list-secret-keys | grep -q "^sec"'

exit "$status"
