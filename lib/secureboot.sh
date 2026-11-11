# shellcheck shell=bash
# Secure Boot signing, on when SB_KEY and SB_CERT are set (see build.sh).
# Machines enroll SB_CA_CERT, so the signing key can rotate without a new
# enrollment.

SB_KEY="${SB_KEY:-}"
SB_CERT="${SB_CERT:-}"
SB_CA_CERT="${SB_CA_CERT:-}"

# Fedora's shim, signed by the Microsoft UEFI CA. Renovate bumps the version,
# ci/renovate-hashes.sh writes the sha512.
readonly SHIM_VERSION="16.1-7"
readonly SHIM_URL="https://kojipkgs.fedoraproject.org/packages/shim/${SHIM_VERSION%-*}/${SHIM_VERSION#*-}/x86_64/shim-x64-$SHIM_VERSION.x86_64.rpm"
readonly SHIM_SHA512="642f7bd66f9d420fed5d5686d968a2065af445b4e7ba3d27a0a4f5852aefadd1835c485968e7bdc7cea5f377095bd3efcc8636837e3059a19cfab1c777e218f0"

# The enrollment cert in the root layer, an ExtraTrees= source of mkosi.images/root
readonly SB_TREE="$OUTPUT_DIR/.secureboot/root"
readonly SB_CERT_PATH="usr/share/garuda/secureboot/garuda-secureboot.crt"

sb_enabled() {
  [[ -n "$SB_KEY" ]]
}

sb_is_uri() {
  [[ "$SB_KEY" == pkcs11:* ]]
}

sb_enroll_cert() {
  echo "${SB_CA_CERT:-$SB_CERT}"
}

check_secureboot() {
  if [[ -z "$SB_KEY" && -z "$SB_CERT" ]]; then
    [[ -z "$SB_CA_CERT" ]] || die "SB_CA_CERT needs SB_KEY and SB_CERT"
    return
  fi

  [[ -n "$SB_KEY" && -n "$SB_CERT" ]] || die "set both SB_KEY and SB_CERT, or neither"
  [[ -f "$SB_CERT" ]] || die "SB_CERT $SB_CERT not found"
  [[ -z "$SB_CA_CERT" || -f "$SB_CA_CERT" ]] || die "SB_CA_CERT $SB_CA_CERT not found"

  sb_is_uri || [[ -f "$SB_KEY" ]] || die "SB_KEY $SB_KEY is neither a file nor a pkcs11: URI"

  # Absolute, because the post-build steps and the container see other directories
  SB_CERT="$(readlink -f "$SB_CERT")"
  [[ -z "$SB_CA_CERT" ]] || SB_CA_CERT="$(readlink -f "$SB_CA_CERT")"

  sb_is_uri || SB_KEY="$(readlink -f "$SB_KEY")"

  # The host may lack openssl, the post step checks again in the tools tree
  if command -v openssl >/dev/null; then
    check_secureboot_certs
  fi
}

# Fails before the build instead of at sbverify after it
check_secureboot_certs() {
  sb_enabled || return 0

  local err
  if [[ -n "$SB_CA_CERT" ]] && ! err="$(openssl verify -CAfile "$SB_CA_CERT" "$SB_CERT" 2>&1)"; then
    die "SB_CERT $SB_CERT is not issued by SB_CA_CERT $SB_CA_CERT: ${err//$'\n'/ }"
  fi

  if ! sb_is_uri; then
    [[ "$(openssl x509 -pubkey -noout -in "$SB_CERT")" == "$(openssl pkey -pubout -in "$SB_KEY" 2>/dev/null)" ]] ||
      die "SB_KEY $SB_KEY does not match SB_CERT $SB_CERT"
  fi
}

# Empty for unsigned builds, mkosi needs the directory anyway
write_secureboot_tree() {
  remove_output "$SB_TREE"
  mkdir -p "$SB_TREE"
  if [[ -n "$SB_CERT" ]]; then
    install -Dm0644 "$(sb_enroll_cert)" "$SB_TREE/$SB_CERT_PATH"
  fi
}

# Part of the root stamp of signed builds
sb_stamp() {
  echo "secureboot-cert=$(sha256sum "$(sb_enroll_cert)" | cut -d' ' -f1)"
}

sb_sign() {
  local in="$1" out="$2" source_args=()

  if ! sb_enabled; then
    install -m 0644 "$in" "$out"
    return
  fi

  sb_is_uri && source_args=(--private-key-source=provider:pkcs11)
  /usr/lib/systemd/systemd-sbsign sign --private-key="$SB_KEY" --certificate="$SB_CERT" \
    "${source_args[@]}" --output="$out" "$in" >/dev/null ||
    die "could not sign $in"
}

# One per line, for mapfile
sb_ukify_args() {
  sb_enabled || return 0

  # The UKI signature covers the kernel, and systemd-sbsign cannot check it
  printf '%s\n' --signtool=systemd-sbsign --no-sign-kernel \
    "--secureboot-private-key=$SB_KEY" "--secureboot-certificate=$SB_CERT"

  if sb_is_uri; then
    echo "--signing-provider=pkcs11"
  fi
}

# Against SB_CERT: shim chains it to the enrolled CA
sb_verify() {
  sb_enabled || return 0
  sbverify --cert "$SB_CERT" "$1" >/dev/null 2>&1 || die "$1 has no valid signature by $SB_CERT"
}

# The enrollment cert in DER form, which MokManager reads
sb_write_der() {
  openssl x509 -in "$(sb_enroll_cert)" -outform DER -out "$1"
}

shim_rpm() {
  echo "$PWD/mkosi.cache/shim/${SHIM_URL##*/}"
}

check_shim_rpm() {
  echo "$SHIM_SHA512  $1" | sha512sum --check --quiet ||
    die "$1 does not match the pinned sha512, remove it to download it again"
}

# Before the build, on the host: the post-build steps run in the tools tree and stay offline
download_shim() {
  sb_enabled || return 0
  local rpm
  rpm="$(shim_rpm)"

  if [[ ! -f "$rpm" ]]; then
    log "Downloading shim $SHIM_VERSION"
    mkdir -p "${rpm%/*}"
    curl -fsSL --proto '=https' -o "$rpm.part" "$SHIM_URL"
    mv "$rpm.part" "$rpm"
  fi

  check_shim_rpm "$rpm"
}

# shimx64.efi and mmx64.efi from the rpm of download_shim into a directory
fetch_shim() {
  local dest="$1" rpm
  rpm="$(shim_rpm)"

  [[ -f "$rpm" ]] || die "$rpm missing, download_shim fetches it before the build"
  check_shim_rpm "$rpm"
  mkdir -p "$dest"

  local tmp="$dest/rpm" file
  mkdir -p "$tmp"
  bsdtar -xf "$rpm" -C "$tmp"

  for file in shimx64.efi mmx64.efi; do
    [[ -f "$tmp/usr/lib/efi/shim/$SHIM_VERSION/EFI/fedora/$file" ]] || die "$file missing in $rpm"
    install -m 0644 "$tmp/usr/lib/efi/shim/$SHIM_VERSION/EFI/fedora/$file" "$dest/$file"
  done

  rm -rf "$tmp"
}
