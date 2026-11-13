# shellcheck shell=bash
# chaotic-keyring and chaotic-mirrorlist are not in Arch, so they come from the CDN.

readonly CHAOTIC_CDN="https://cdn-mirror.chaotic.cx/chaotic-aur"

# Key from the chaotic-aur install instructions (long ID 3056513887B78AEB).
# The public key is vendored in ci/chaotic-key.asc, so no keyserver is needed.
# VALIDSIG names the primary key, also for signatures made by a subkey.
readonly CHAOTIC_KEY="EF925EA60F33D0CB85C44AD13056513887B78AEB"
readonly CHAOTIC_KEY_FILE="ci/chaotic-key.asc"

verify_chaotic() {
  local dir="$1" pkg status

  export GNUPGHOME="$dir/gnupg"
  mkdir -m 0700 "$GNUPGHOME"

  gpg --batch --quiet --import "$CHAOTIC_KEY_FILE" ||
    die "could not import the chaotic signing key from $CHAOTIC_KEY_FILE"

  for pkg in keyring mirrorlist; do
    status="$(gpg --batch --status-fd 1 --verify "$dir/$pkg.pkg.tar.zst.sig" "$dir/$pkg.pkg.tar.zst" 2>/dev/null || true)"
    grep -q "^\[GNUPG:\] VALIDSIG .* $CHAOTIC_KEY\$" <<<"$status" ||
      die "chaotic-$pkg: no valid signature by $CHAOTIC_KEY. gpg said: $(grep -o 'VALIDSIG [0-9A-F]*\|BADSIG.*\|ERRSIG.*\|NO_PUBKEY.*' <<<"$status" | head -n1)"
  done

  gpgconf --kill all
  unset GNUPGHOME
}

fetch_chaotic() {
  local refresh="$1"
  local keyrings="$SANDBOX/usr/share/pacman/keyrings"
  local mirrorlist="$SANDBOX/etc/pacman.d/chaotic-mirrorlist"

  if [[ "$refresh" != true && -f "$mirrorlist" ]] && compgen -G "$keyrings/chaotic*.gpg" >/dev/null; then
    return
  fi

  log "Fetching chaotic keyring and mirrorlist"

  (
    tmp="$(mktemp -d)"
    trap 'GNUPGHOME="$tmp/gnupg" gpgconf --kill all 2>/dev/null || true; rm -rf "$tmp"' EXIT

    for pkg in keyring mirrorlist; do
      curl -fsSL --proto '=https' -o "$tmp/$pkg.pkg.tar.zst" "$CHAOTIC_CDN/chaotic-$pkg.pkg.tar.zst"
      curl -fsSL --proto '=https' -o "$tmp/$pkg.pkg.tar.zst.sig" "$CHAOTIC_CDN/chaotic-$pkg.pkg.tar.zst.sig"
    done

    verify_chaotic "$tmp"

    mkdir -p "$keyrings" "$(dirname "$mirrorlist")"
    tar --zstd -xf "$tmp/keyring.pkg.tar.zst" -C "$tmp" usr/share/pacman/keyrings
    cp "$tmp"/usr/share/pacman/keyrings/* "$keyrings/"
    tar --zstd -xf "$tmp/mirrorlist.pkg.tar.zst" -C "$tmp" etc/pacman.d/chaotic-mirrorlist
    cp "$tmp/etc/pacman.d/chaotic-mirrorlist" "$mirrorlist"
  )
}
