#!/usr/bin/env bash
# Usage: virt iso|vm <edition> [--new[=<name>]] [--attach] [--disk] [--ram=<size>]
#   Starts the ISO or VM image as libvirt domain garuda-<iso|vm>-<edition> on
#   qemu:///system, replacing an existing one. See docs/testing.md#libvirt.
#   --new[=<name>]  another domain instead, default name with a timestamp
#   --attach        follow the guest journal, Ctrl+C shuts the domain down
#   --disk          ISO only: empty 30G install disk
#   --ram=<size>    MiB or with a G suffix, default TEST_RAM or 6G
# Environment: VIRT_NETWORK, VIRT_POOL (both default "default").

set -euo pipefail

root="$(git rev-parse --show-toplevel)"
# shellcheck source=lib/env.sh
source "$root/lib/env.sh"
load_env_local "$root"

die() {
  printf '\033[1;31m==> ERROR:\033[0m %s\n' "$*" >&2
  exit 1
}

kind="${1:-}"
edition="${2:-}"
[[ "$kind" == iso || "$kind" == vm ]] && [[ -n "$edition" && "$edition" != --* ]] ||
  die "usage: build virt iso|vm <edition> [--new[=<name>]] [--attach] [--disk] [--ram=<size>]"
shift 2

name="garuda-$kind-$edition"
new=false
attach=false
disk=false
ram="${TEST_RAM:-6G}"
for arg in "$@"; do
  case "$arg" in
    --new) new=true name="$name-$(date +%Y%m%d-%H%M%S)" ;;
    --new=*) new=true name="${arg#--new=}" ;;
    --attach) attach=true ;;
    --disk) disk=true ;;
    --ram=*) ram="${arg#--ram=}" ;;
    *) die "unknown option $arg" ;;
  esac
done

[[ "$disk" == false || "$kind" == iso ]] || die "--disk is for the ISO only"
[[ -d "$root/mkosi.images/desktop/mkosi.profiles/$edition" ]] || die "unknown edition $edition, see scripts/editions.sh"

case "$ram" in
  *G) ram_mib=$((${ram%G} * 1024)) ;;
  *) ram_mib="$ram" ;;
esac

if [[ "$kind" == iso ]]; then
  source_image="$root/mkosi.output/garuda-$edition.iso"
  source_format=raw
else
  source_image="$root/mkosi.output/garuda-vm-$edition.qcow2"
  source_format=qcow2
fi

[[ -e "$source_image" ]] || die "no image at $source_image, run: build $kind $edition"
source_image="$(readlink -f "$source_image")"

virsh=(virsh --connect qemu:///system --quiet)
network="${VIRT_NETWORK:-default}"
pool="${VIRT_POOL:-default}"
running() { [[ "$("${virsh[@]}" domstate "$name" 2>/dev/null)" == running ]]; }

[[ "$("${virsh[@]}" net-info "$network" 2>/dev/null | awk '/^Active:/ {print $2}')" == yes ]] ||
  die "libvirt network $network is not active: virsh -c qemu:///system net-start $network, or set VIRT_NETWORK"

if "${virsh[@]}" dominfo "$name" >/dev/null 2>&1; then
  [[ "$new" == false ]] || die "a domain $name exists already"
  echo "==> Replacing $name"
  "${virsh[@]}" destroy "$name" >/dev/null 2>&1 || true
  "${virsh[@]}" undefine "$name" --nvram --tpm --remove-all-storage >/dev/null
fi

share="${XDG_DATA_HOME:-$HOME/.local/share}/garuda-libvirt/share"
mkdir -p "$share"

# The overlay needs the virtual size of the image, systemd-repart grows the VM root to it
size="$(qemu-img info --output=json -f "$source_format" "$source_image" | jq '."virtual-size"')"
for vol in "$name.qcow2" "$name-install.qcow2"; do
  "${virsh[@]}" vol-delete --pool "$pool" "$vol" >/dev/null 2>&1 || true
done

# vol-create-as only takes backing files that belong to a pool
"${virsh[@]}" vol-create "$pool" /dev/stdin >/dev/null <<EOF
<volume>
  <name>$name.qcow2</name>
  <capacity unit="bytes">$size</capacity>
  <target><format type="qcow2"/></target>
  <backingStore><path>$source_image</path><format type="$source_format"/></backingStore>
</volume>
EOF

disks=(--disk "vol=$pool/$name.qcow2,bus=virtio,boot.order=1")
if [[ "$disk" == true ]]; then
  "${virsh[@]}" vol-create-as "$pool" "$name-install.qcow2" 30G --format qcow2 >/dev/null
  disks+=(--disk "vol=$pool/$name-install.qcow2,bus=virtio,boot.order=2")
fi

# journald in the guest sends its journal to this host vsock port, see systemd.system-credentials(7)
port=$((20000 + $(cksum <<<"$name" | cut -d' ' -f1) % 10000))
journal="${XDG_STATE_HOME:-$HOME/.local/state}/garuda-libvirt/$name"
rm -rf -- "$journal"
mkdir -p "$journal"

# Journal files on btrfs copy-on-write are slow, journal-remote warns about it
chattr +C "$journal" 2>/dev/null || true

receiver=""
if [[ "$attach" == true ]]; then
  # journald connects once at boot, so listen before the domain starts
  journal_remote=""
  for candidate in /usr/lib/systemd/systemd-journal-remote /run/current-system/sw/lib/systemd/systemd-journal-remote; do
    [[ -x "$candidate" ]] && journal_remote="$candidate" && break
  done

  [[ -n "$journal_remote" ]] || die "--attach needs systemd-journal-remote (Arch: package systemd-journal-remote)"
  "$journal_remote" --split-mode=none \
    --listen-raw="vsock::$port" --output="$journal/remote.journal" &
  receiver=$!
fi

virt-install --connect qemu:///system --name "$name" \
  --osinfo archlinux --memory "$ram_mib" --vcpus 4 \
  --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no \
  --tpm backend.type=emulator,model=tpm-crb \
  "${disks[@]}" --import \
  --network "network=$network,model=virtio" \
  --graphics spice --video virtio \
  --channel spicevmc \
  --channel unix,target.type=virtio,target.name=org.qemu.guest_agent.0 \
  --input tablet,bus=usb \
  --memorybacking source.type=memfd,access.mode=shared \
  --filesystem "source.dir=$share,target.dir=garuda-share,driver.type=virtiofs" \
  --vsock cid.auto=yes \
  --qemu-commandline="-smbios type=11,value=io.systemd.credential:journal.forward_to_socket=vsock-stream:2:$port" \
  --noautoconsole >/dev/null

cat <<EOF
==> Started $name
    window  virt-manager --connect qemu:///system --show-domain-console $name
    share   $share, guest: sudo mount -t virtiofs garuda-share /mnt
    remove  virsh -c qemu:///system undefine $name --nvram --tpm --remove-all-storage
EOF

[[ "$attach" == true ]] || exit 0

stopped=false
shut_down() {
  [[ "$stopped" == false ]] || return 0
  stopped=true
  echo "==> Shutting down $name"
  "${virsh[@]}" shutdown "$name" >/dev/null 2>&1 || true
  for _ in $(seq 60); do
    running || break
    sleep 1
  done
  "${virsh[@]}" destroy "$name" >/dev/null 2>&1 || true
  kill "$receiver" 2>/dev/null || true
  echo "==> Journal kept in $journal: journalctl --directory=$journal"
}
trap shut_down INT TERM

echo "==> Following the guest journal, Ctrl+C shuts $name down"
until journalctl --directory="$journal" -n 1 -q 2>/dev/null | grep -q .; do
  running || break
  sleep 1
done

journalctl --directory="$journal" --follow --no-tail &
follower=$!
while running; do
  sleep 2 &
  wait $! || break
done

kill "$follower" 2>/dev/null || true
shut_down
