#!/usr/bin/env bash
# Usage: vm-test <edition> [--keep] [--serial] [--ssh] [--ram=<size>] [--version=<YYYYMMDD>]
#   Boots mkosi.output/garuda-vm-<edition>.qcow2 with systemd-vmspawn in a
#   window, with UEFI and a TPM. The VM writes to an overlay in mkosi.cache/qemu,
#   so the built image stays unchanged.
#   --keep         reuse the overlay, firmware variables and TPM of the last run
#                  instead of starting from the built image
#   --serial       console in this terminal instead of a window
#   --ssh          root login over vsock with the first key of ssh-add -L or ~/.ssh/*.pub,
#                  prints the ssh command
#   --ram=<size>   RAM of the VM, default TEST_RAM or 6G
#   --version=<v>  an older image of the edition, see build ls
#   The edition defaults to EDITION, the CPU count to TEST_CPUS or 4.

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

edition="${EDITION:-}"
keep=false
ssh=false
console=gui
ram="${TEST_RAM:-6G}"
version=""

for arg in "$@"; do
  case "$arg" in
    --keep) keep=true ;;
    --serial) console=interactive ;;
    --ssh) ssh=true ;;
    --ram=*) ram="${arg#--ram=}" ;;
    --version=*) version="${arg#--version=}" ;;
    --*) die "unknown option $arg" ;;
    *) edition="$arg" ;;
  esac
done

check_edition "$root" "$edition"
ram="$(ram_mib "$ram")M"
image="$(image_path "$root" vm "$edition" "$version")"

# build.sh creates it, mkosi.cache belongs to root
state="$root/mkosi.cache/qemu"
overlay="$state/vm-test-$edition.qcow2"
vars="$state/vm-test-$edition-vars.fd"
tpm="$state/vm-test-$edition-tpm"
journal="$state/vm-test-journal"

check_state_dir "$state"

# The overlay has the virtual size of the image, systemd-repart grows root to it
if [[ "$keep" == false || ! -e "$overlay" ]]; then
  rm -rf "$overlay" "$vars" "$tpm"
  qemu-img create -q -f qcow2 -F qcow2 -b "$image" "$overlay"
fi

rm -rf "$journal"
mkdir -p "$journal"

# UEFI without Secure Boot: the UKIs of the image are built on it, unsigned
args=(
  --image="$overlay" --image-format=qcow2
  --firmware=uefi --secure-boot=no --efi-nvram-state="$vars"
  --tpm=yes --tpm-state="$tpm"
  --ram="$ram" --cpus="${TEST_CPUS:-4}"
  --console="$console"
  --network-user-mode
  --register=no
  --forward-journal="$journal/"
)

if [[ "$ssh" == true ]]; then
  key="$(ssh-add -L 2>/dev/null | head -n 1 || true)"
  if [[ -z "$key" || "$key" != ssh-* ]]; then
    for file in "$HOME"/.ssh/id_ed25519.pub "$HOME"/.ssh/id_ecdsa.pub "$HOME"/.ssh/id_rsa.pub; do
      [[ -f "$file" ]] && key="$(<"$file")" && break
    done
  fi

  [[ "$key" == ssh-* || "$key" == ecdsa-* ]] || die "--ssh needs a public key in ssh-add -L or ~/.ssh/id_*.pub"

  proxy=""
  vmspawn="$(readlink -f "$(command -v systemd-vmspawn)")"
  for candidate in "${vmspawn%/bin/*}/lib/systemd/systemd-ssh-proxy" /usr/lib/systemd/systemd-ssh-proxy; do
    [[ -x "$candidate" ]] && proxy="$candidate" && break
  done

  [[ -n "$proxy" ]] || die "--ssh needs systemd-ssh-proxy of systemd 256 or newer"

  # systemd-ssh-generator in the guest binds sshd to vsock, tmpfiles writes the
  # key from the credential to /root/.ssh/authorized_keys
  cid=$((1000 + $(cksum <<<"vm-test-$edition" | cut -d' ' -f1) % 100000))
  args+=(--vsock=yes --vsock-cid="$cid" --pass-ssh-key=no --set-credential="ssh.authorized_keys.root:$key")
fi

log "Image: $image"
log "Overlay: $overlay"
log "Journal: journalctl --directory=$journal"
log "Login: garuda / garuda"
if [[ "$ssh" == true ]]; then
  log "SSH: ssh -o ProxyCommand='$proxy %h %p' -o ProxyUseFdpass=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@vsock/$cid"
fi

exec systemd-vmspawn "${args[@]}"
