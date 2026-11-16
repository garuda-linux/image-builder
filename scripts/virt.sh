#!/usr/bin/env bash
# Usage: virt iso|vm [edition] [--new[=<name>]] [--open] [--attach] [--disk] [--secure-boot] [--ram=<size>]
#                         [--version=<YYYYMMDD>]
#        virt list
#        virt rm <domain>...|--all
#   Starts the ISO or VM image as libvirt domain garuda-<iso|vm>-<edition> on
#   qemu:///system, replacing an existing one. See docs/testing.md#libvirt.
#   The edition defaults to EDITION, the CPU count to TEST_CPUS or 4.
#   --new[=<name>]  another domain instead, default name with a timestamp
#   --open          open the console in virt-manager
#   --attach        follow the guest journal, Ctrl+C shuts the domain down
#   --disk          ISO only: empty 30G install disk
#   --secure-boot   ISO only: Secure Boot on with the Microsoft keys, shim asks
#                   MokManager to enroll the ISO cert
#   --ram=<size>    N, NM, NMiB, NG or NGiB, default TEST_RAM or 6G
#   --version=<v>   an older image of the edition (YYYYMMDD), see build ls
#   list            the garuda-* domains and their state
#   rm              removes domains with NVRAM, TPM, volumes and journal,
#                   --all every garuda-* domain
# Environment: VIRT_NETWORK, VIRT_POOL (both default "default").

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

virsh=(virsh --connect qemu:///system --quiet)
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/garuda-libvirt"

garuda_domains() {
  "${virsh[@]}" list --all --name | grep '^garuda-' || true
}

remove_domain() {
  "${virsh[@]}" destroy "$1" >/dev/null 2>&1 || true
  "${virsh[@]}" undefine "$1" --nvram --tpm --remove-all-storage >/dev/null
}

kind="${1:-}"
case "$kind" in
  list)
    [[ $# -eq 1 ]] || die "usage: build virt list"

    garuda_domains | while read -r domain; do
      printf '%-40s %s\n' "$domain" "$("${virsh[@]}" domstate "$domain")"
    done

    exit 0
    ;;
  rm)
    shift
    [[ $# -ge 1 ]] || die "usage: build virt rm <domain>...|--all"

    domains=("$@")
    [[ "$*" != --all ]] || mapfile -t domains < <(garuda_domains)

    for domain in "${domains[@]}"; do
      [[ "$domain" != --* ]] || die "unknown option $domain, --all goes alone"
      "${virsh[@]}" dominfo "$domain" >/dev/null 2>&1 || die "no domain $domain"

      remove_domain "$domain"
      rm -rf -- "${state_dir:?}/$domain"
      log "Removed $domain"
    done

    exit 0
    ;;
  iso | vm) shift ;;
  *) die "usage: build virt iso|vm [edition] [options], build virt list or build virt rm <domain>...|--all" ;;
esac

edition="${EDITION:-}"
if [[ $# -ge 1 && "$1" != --* ]]; then
  edition="$1"
  shift
fi

check_edition "$root" "$edition"

name="garuda-$kind-$edition"
new=false
open=false
attach=false
disk=false
secure_boot=false
ram="${TEST_RAM:-6G}"
version=""
for arg in "$@"; do
  case "$arg" in
    --version=*) version="${arg#--version=}" ;;
    --new) new=true name="$name-$(date +%Y%m%d-%H%M%S)" ;;
    --new=*) new=true name="${arg#--new=}" ;;
    --open) open=true ;;
    --attach) attach=true ;;
    --disk) disk=true ;;
    --secure-boot) secure_boot=true ;;
    --ram=*) ram="${arg#--ram=}" ;;
    *) die "unknown option $arg" ;;
  esac
done

[[ "$disk" == false || "$kind" == iso ]] || die "--disk is for the ISO only"

# The UKIs of the VM image are built on it, unsigned
[[ "$secure_boot" == false || "$kind" == iso ]] || die "--secure-boot is for the ISO only"

ram_mib="$(ram_mib "$ram")"
source_image="$(image_path "$root" "$kind" "$edition" "$version")"

source_format=qcow2
[[ "$kind" == vm ]] || source_format=raw

network="${VIRT_NETWORK:-default}"
pool="${VIRT_POOL:-default}"
running() { [[ "$("${virsh[@]}" domstate "$name" 2>/dev/null)" == running ]]; }

[[ "$("${virsh[@]}" net-info "$network" 2>/dev/null | awk '/^Active:/ {print $2}')" == yes ]] ||
  die "libvirt network $network is not active: virsh -c qemu:///system net-start $network, or set VIRT_NETWORK"

if "${virsh[@]}" dominfo "$name" >/dev/null 2>&1; then
  [[ "$new" == false ]] || die "a domain $name exists already"
  log "Replacing $name"
  remove_domain "$name"
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
journal="$state_dir/$name"
rm -rf -- "$journal"
mkdir -p "$journal"

# Journal files on btrfs copy-on-write are slow, journal-remote warns about it
chattr +C "$journal" 2>/dev/null || true

# systemd-fstab-generator in the guest mounts the share from this credential.
# Base64, as virt-install splits --qemu-commandline at spaces.
fstab="$(printf 'garuda-share /mnt/garuda-share virtiofs nofail 0 0\n' | base64 -w0)"

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

boot=(--boot "uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no")
if [[ "$secure_boot" == true ]]; then
  boot=(--boot "uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=yes,firmware.feature1.name=enrolled-keys,firmware.feature1.enabled=yes"
    --features smm.state=on)
fi

virt-install --connect qemu:///system --name "$name" \
  --osinfo archlinux --memory "$ram_mib" --vcpus "${TEST_CPUS:-4}" \
  "${boot[@]}" \
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
  --qemu-commandline="-smbios type=11,value=io.systemd.credential.binary:fstab.extra=$fstab" \
  --noautoconsole >/dev/null

log "Started $name"
cat <<EOF
    window  virt-manager --connect qemu:///system --show-domain-console $name
    share   $share, guest: /mnt/garuda-share
    remove  build virt rm $name
EOF

if [[ "$open" == true ]]; then
  command -v virt-manager >/dev/null || die "--open needs virt-manager"
  setsid virt-manager --connect qemu:///system --show-domain-console "$name" >/dev/null 2>&1 &
fi

[[ "$attach" == true ]] || exit 0

stopped=false
shut_down() {
  [[ "$stopped" == false ]] || return 0
  stopped=true
  log "Shutting down $name"
  "${virsh[@]}" shutdown "$name" >/dev/null 2>&1 || true
  for _ in $(seq 60); do
    running || break
    sleep 1
  done
  "${virsh[@]}" destroy "$name" >/dev/null 2>&1 || true
  kill "$receiver" 2>/dev/null || true
  log "Journal kept in $journal: journalctl --directory=$journal"
}
trap shut_down INT TERM

log "Following the guest journal, Ctrl+C shuts $name down"
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
