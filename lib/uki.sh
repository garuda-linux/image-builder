# shellcheck shell=bash
# Generic UKIs of the root layer, rescue and Easy Anti-Cheat, signed when
# SB_KEY is set. No root=: systemd-gpt-auto-generator finds the root by the
# partition type Calamares sets, so one signed command line fits every install.

readonly UKI_CMDLINE_COMMON="rw rootflags=subvol=@"

# Epic requires lockdown and no kexec. lsm= keeps the BPF LSM of linux-garuda.
readonly UKI_CMDLINE_EAC="lockdown=integrity module.sig_enforce=1 sysctl.kernel.kexec_load_disabled=1 intel_iommu=on iommu.passthrough=0 lsm=landlock,lockdown,yama,integrity,bpf"

build_generic_uki() {
  local tree="$1" kver="$2" kernel="$3" work="$4" uki="$5" title="$6" cmdline="$7" sign_args=()
  local initrd="$tree/boot/initramfs-$kernel-fallback.img"
  [[ -f "$initrd" ]] || die "$initrd not found, dracut-install-garuda builds it in the root layer"

  # Its own title in the boot menu
  sed "s/^PRETTY_NAME=\"\(.*\)\"$/PRETTY_NAME=\"\1 ($title)\"/" "$tree/usr/lib/os-release" >"$work/os-release"
  echo "$cmdline" >"$work/cmdline"
  mapfile -t sign_args < <(sb_ukify_args)

  log "Building ${uki##*/}"

  # The initramfs of dracut has the microcode already
  ukify build --stub="$tree/usr/lib/systemd/boot/efi/linuxx64.efi.stub" \
    --linux="$tree/usr/lib/modules/$kver/vmlinuz" --initrd="$initrd" \
    --uname="$kver" --os-release="@$work/os-release" --cmdline="@$work/cmdline" \
    "${sign_args[@]}" --output="$uki" >/dev/null
  sb_verify "$uki"

  (cd "${uki%/*}" && sha256sum "${uki##*/}" >"${uki##*/}.sha256")
}

post_uki() {
  local tree="$OUTPUT_DIR/root" info kver kernel
  info="$(tree_kernel "$tree")"
  kver="${info%%$'\n'*}" kernel="${info#*$'\n'}"

  local work="$OUTPUT_DIR/uki-work"
  remove_output "$work"
  mkdir -p "$work"

  local rescue="$OUTPUT_DIR/garuda-$kernel-$VERSION.efi" eac="$OUTPUT_DIR/garuda-$kernel-$VERSION-eac.efi"
  build_generic_uki "$tree" "$kver" "$kernel" "$work" "$rescue" "generic" "$UKI_CMDLINE_COMMON"
  build_generic_uki "$tree" "$kver" "$kernel" "$work" "$eac" "Easy Anti-Cheat" "$UKI_CMDLINE_COMMON $UKI_CMDLINE_EAC"
  remove_output "$work"

  # Only the newest pair stays, the glob matches both names
  local old
  for old in "$OUTPUT_DIR/garuda-$kernel-"[0-9]*.efi; do
    [[ -e "$old" && "$old" != "$rescue" && "$old" != "$eac" ]] || continue
    log "Removing the older ${old##*/}"
    rm -f "$old" "$old.sha256"
  done

  ln -sf "${rescue##*/}" "$OUTPUT_DIR/garuda-$kernel.efi"
  ln -sf "${eac##*/}" "$OUTPUT_DIR/garuda-$kernel-eac.efi"

  log "Done: $rescue and $eac"
}
