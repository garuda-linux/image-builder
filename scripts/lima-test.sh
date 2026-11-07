#!/usr/bin/env bash
# Usage: lima-test [--keep]
#   --keep  keep the VM afterwards (limactl shell <name>)
# UEFI only: the image boots systemd-boot.

set -euo pipefail

root="$(git rev-parse --show-toplevel)"
image="$root/mkosi.output/garuda-lima.qcow2"
keep=false

for arg in "$@"; do
  case "$arg" in
    --keep) keep=true ;;
    *)
      echo "Unknown option $arg" >&2
      exit 1
      ;;
  esac
done

if [[ ! -e "$image" ]]; then
  echo "No image at $image. Run: build lima" >&2
  exit 1
fi

name="garuda-test"
location="$(readlink -f "$image")"

limactl delete --force "$name" >/dev/null 2>&1 || true
limactl start --name="$name" --tty=false \
  --set ".images = [{\"location\": \"$location\", \"arch\": \"x86_64\"}]" \
  "$root/lima/garuda.yaml"

status=0
check() {
  local desc="$1"
  shift
  if limactl shell "$name" -- "$@" >/dev/null 2>&1; then
    printf '  \033[1;32mok\033[0m    %s\n' "$desc"
  else
    printf '  \033[1;31mfail\033[0m  %s\n' "$desc"
    status=1
  fi
}

echo "Checking $name:"
check "sshd active" systemctl is-active sshd
check "root on btrfs subvolume @" sh -c 'findmnt -n -o OPTIONS / | grep -q "subvol=/@"'
check "booted by systemd-boot" sh -c 'bootctl status 2>/dev/null | grep -A1 "Current Boot Loader:" | grep -q systemd-boot'
check "kernel started from a UKI (systemd-stub)" sh -c 'test -e /sys/firmware/efi/efivars/StubInfo-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f'
# The image ships no keyring. pacman-init.service makes one on the first boot.
check "own pacman keyring" sh -c 'sudo gpg --homedir /etc/pacman.d/gnupg --list-secret-keys | grep -q "^sec"'
check "pacman syncs the repositories" sudo pacman -Sy --noconfirm

if [[ "$keep" == false ]]; then
  limactl delete --force "$name"
fi

exit "$status"
