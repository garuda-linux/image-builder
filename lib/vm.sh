# shellcheck shell=bash
# The VM image of an edition: the desktop layer on the disk layout of
# lib/disk.sh, with what Calamares does on an install. The values that differ
# per edition (user groups, kernel options) come from the Calamares
# configuration of the edition, so the image matches an install of it.

readonly VM_SIZE=40G
readonly VM_USER=garuda

# calamares_conf <edition> <module>: the configuration file of a Calamares
# module, the edition's own when its live profile has one
calamares_conf() {
  local own="mkosi.images/live/mkosi.profiles/$1/mkosi.extra/etc/calamares/modules/$2.conf"
  if [[ -f "$own" ]]; then
    echo "$own"
  else
    echo "mkosi.images/live/mkosi.extra/etc/calamares/modules/$2.conf"
  fi
}

# yaml_list <file> <key>: the items of a top-level YAML list, in the block form
# (- item) or the flow form ([ item, ... ]), without quotes
yaml_list() {
  awk -v key="$2" '
    $0 ~ "^" key ":" {
      rest = substr($0, length(key) + 2)
      if (rest ~ /\[/) {
        gsub(/[][",]/, " ", rest)
        n = split(rest, items, " ")
        for (i = 1; i <= n; i++) print items[i]
        exit
      }
      inlist = 1
      next
    }
    inlist && /^[[:space:]]*-/ {
      item = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", item)
      sub(/[[:space:]]+#.*$/, "", item)
      gsub(/"/, "", item)
      print item
      next
    }
    inlist && /^[^[:space:]#]/ { exit }
  ' "$1"
}

# Locale, keymap, time zone and hostname, which Calamares asks for on installs
vm_system_settings() {
  local edition="$1"

  log "Writing locale, keymap, time zone and hostname"
  sed -i 's/^#\(en_US.UTF-8 UTF-8\)/\1/' "$DISK_MNT/etc/locale.gen"
  arch-chroot "$DISK_MNT" locale-gen
  arch-chroot "$DISK_MNT" systemd-firstboot --force \
    --locale=en_US.UTF-8 --timezone=UTC --hostname="garuda-$edition"

  # Not through systemd-firstboot, it would drop the console font from vconsole.conf
  sed -i '/^KEYMAP=/d' "$DISK_MNT/etc/vconsole.conf"
  echo "KEYMAP=us" >>"$DISK_MNT/etc/vconsole.conf"
}

# The user of the image, as the users module of Calamares creates it: the
# default groups of the edition, sudo through wheel. The password is garuda,
# not expired: plasmalogin hangs on the password change of an expired one.
# Instead, a notification after the first login asks to change it
# (/usr/lib/garuda/vm-password-reminder of mkosi.profiles/vm).
vm_user() {
  local edition="$1" conf group groups=()
  conf="$(calamares_conf "$edition" users)"

  # Groups of packages the edition does not have stay out
  while IFS= read -r group; do
    if arch-chroot "$DISK_MNT" getent group "$group" >/dev/null; then
      groups+=("$group")
    else
      log "Group $group of $conf does not exist in the image, left out"
    fi
  done < <(yaml_list "$conf" defaultGroups)

  log "Creating the user $VM_USER (groups ${groups[*]})"
  arch-chroot "$DISK_MNT" useradd -m -s /bin/bash -G "$(
    IFS=,
    echo "${groups[*]}"
  )" "$VM_USER"
  echo "$VM_USER:$VM_USER" | arch-chroot "$DISK_MNT" chpasswd

  # Removes itself once the notification was shown
  local autostart="/home/$VM_USER/.config/autostart"
  mkdir -p "$DISK_MNT$autostart"
  cat >"$DISK_MNT$autostart/garuda-vm-password.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Garuda VM password reminder
Exec=/usr/lib/garuda/vm-password-reminder
NoDisplay=true
X-GNOME-Autostart-enabled=true
DESKTOP
  arch-chroot "$DISK_MNT" chown -R "$VM_USER:$VM_USER" "/home/$VM_USER/.config"

  install -m 0440 /dev/stdin "$DISK_MNT/etc/sudoers.d/10-installer" <<'SUDO'
%wheel ALL=(ALL:ALL) ALL
SUDO
}

# The snapshots subvolume of the snapper config root, which postcfg of
# Calamares creates on installs. mkosi.repart copied /.snapshots, if at all,
# as a plain directory.
vm_snapshots() {
  local dir="$DISK_MNT/.snapshots"
  log "Creating the subvolume /.snapshots"
  if [[ -d "$dir" ]] && ! btrfs subvolume show "$dir" >/dev/null 2>&1; then
    rmdir "$dir"
  fi
  [[ -d "$dir" ]] || btrfs subvolume create "$dir" >/dev/null
  chmod 0750 "$dir"
}

post_vm() {
  local edition="$1" raw="$OUTPUT_DIR/garuda-vm.raw" params

  # The kernel options of the edition's bootloader.conf, for example the TTY
  # colours of mokka. root=, rootflags= and rw come from disk_boot.
  mapfile -t params < <(yaml_list "$(calamares_conf "$edition" bootloader)" kernelParams)

  disk_mount "$raw"
  vm_system_settings "$edition"
  vm_user "$edition"
  vm_snapshots
  disk_fstab

  # The desktop preset disables it, as postcfg of Calamares makes the keyring on
  # installs. A preset overriding that one would fail check_presets.
  log "Enabling pacman-init.service for the first boot"
  systemctl --root="$DISK_MNT" enable pacman-init.service

  # vm_system_settings already ran it. At boot it deadlocks with bootvine on the console
  log "Masking systemd-firstboot.service"
  systemctl --root="$DISK_MNT" mask systemd-firstboot.service

  disk_boot "${params[@]}"
  disk_unmount

  disk_qcow2 "$raw" "garuda-vm-$edition" "$VM_SIZE"
}
