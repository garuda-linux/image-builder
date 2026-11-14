#!/usr/bin/env bash
# Usage: boot-check <OCI layout or image directory>
#   Reruns itself with sudo. A directory is booted with a volatile overlay and stays unchanged.

set -euo pipefail

target="${1:?usage: boot-check <OCI layout or directory>}"
timeout=300

fail() {
  echo "boot check failed: $*" >&2
  exit 1
}

[[ $EUID -eq 0 ]] || exec sudo "$0" "$@"

work="$(mktemp -d /var/tmp/boot-check.XXXXXX)"
trap 'rm -rf --one-file-system "$work"' EXIT
mkdir "$work/out"

nspawn_root=()
if [[ -f "$target/oci-layout" ]]; then
  # Layers in order: a file replaces a directory below it, whiteouts (.wh.<name>)
  # delete. No jq: it is not on the sudo PATH everywhere.
  manifest="$(grep -o '"digest": *"sha256:[0-9a-f]*"' "$target/index.json" | head -n1 | grep -o '[0-9a-f]\{64\}')"
  mapfile -t layers < <(sed 's/.*"layers"//' "$target/blobs/sha256/$manifest" |
    grep -o '"digest": *"sha256:[0-9a-f]*"' | grep -o '[0-9a-f]\{64\}')
  ((${#layers[@]})) || fail "no layer found in $target"

  root="$work/root"
  mkdir "$root"

  for layer in "${layers[@]}"; do
    while IFS= read -r entry; do
      [[ "$entry" == */ || -L "$root/$entry" || ! -d "$root/$entry" ]] || rm -rf -- "${root:?}/$entry"
    done < <(tar -tf "$target/blobs/sha256/$layer")
    tar --numeric-owner --xattrs --xattrs-include='*' -xf "$target/blobs/sha256/$layer" -C "$root"
    while IFS= read -r -d '' wh; do
      dir="${wh%/*}"
      rm -rf -- "${dir:?}/${wh##*/.wh.}" "$wh"
    done < <(find "$root" -name '.wh.*' -print0)
  done

  nspawn_root=(--directory="$root")
elif [[ -d "$target/usr" ]]; then
  root="$target"
  nspawn_root=(--directory="$root" --volatile=overlay)
else
  fail "$target is neither an OCI layout nor an image directory"
fi

id="$(cat "$root/etc/machine-id" 2>/dev/null || true)"
case "$id" in
  '' | uninitialized) ;;
  *) fail "the image ships a machine ID ($id)" ;;
esac

[[ ! -e "$root/etc/pacman.d/gnupg/trustdb.gpg" ]] ||
  fail "the image ships a pacman keyring (shared private master key)"

# The check runs as a unit inside the machine and reports through a bound
# directory, so the host needs no systemd (CI container)
cat >"$work/check.sh" <<'EOF'
#!/bin/sh
out=/run/boot-check/out
timeout 240 systemctl is-system-running --wait >"$out/state" 2>&1
systemctl list-units --failed --plain --no-legend >"$out/failed" 2>&1
busctl call org.freedesktop.systemd1 /org/freedesktop/systemd1 \
  org.freedesktop.DBus.Peer Ping >/dev/null 2>&1 && echo yes >"$out/dbus"
systemctl --no-block poweroff
EOF
chmod 0755 "$work/check.sh"

cat >"$work/boot-check.service" <<'EOF'
[Unit]
Description=image-builder boot check
After=basic.target

[Service]
# simple: the check must not hold up the boot it waits for
Type=simple
ExecStart=/run/boot-check/check.sh
EOF

echo "Booting $target"
status=0

# -k: nspawn turns SIGTERM into SIGRTMIN+3, which a hung systemd ignores.
# The CI container has no host machine ID and no system bus. --keep-unit: without
# it, nspawn asks systemd over D-Bus for a scope unit.
# systemd-firstboot masked for the check: the machine ID is "uninitialized", so
# it would prompt for the timezone on a TTY that --console=pipe does not have
# (systemd.firstboot=off on the command line does not reach it in a container).
# The Lima and VM images mask it, the bare layers and the distrobox image do not.
timeout -k 30 "$timeout" systemd-nspawn --quiet --register=no --keep-unit --private-network --link-journal=no \
  --resolv-conf=off --console=pipe --machine=boot-check "${nspawn_root[@]}" \
  --bind-ro="$work/check.sh:/run/boot-check/check.sh" \
  --bind-ro="$work/boot-check.service:/run/systemd/system/boot-check.service" \
  --bind-ro=/dev/null:/run/systemd/system/systemd-firstboot.service \
  --bind="$work/out:/run/boot-check/out" \
  --boot -- systemd.wants=boot-check.service \
  </dev/null >"$work/console.log" 2>&1 || status=$?

state="$(cat "$work/out/state" 2>/dev/null || true)"
echo "state: ${state:-no answer}"
if [[ "$state" != running ]]; then
  if [[ -s "$work/out/failed" ]]; then
    echo "failed units:"
    sed 's/^/  /' "$work/out/failed"
  fi
  echo "last console lines (nspawn exit $status):"
  tail -n 40 "$work/console.log" | sed 's/^/  /'
  fail "systemd is ${state:-not answering}, not running"
fi

[[ -f "$work/out/dbus" ]] || fail "systemd does not answer on D-Bus"
echo "$target boots, no failed units, D-Bus answers"
