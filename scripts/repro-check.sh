#!/usr/bin/env bash
# Usage: repro-check [edition]
#   Builds the ISO of the edition (default mokka), the generic UKIs and the
#   distrobox image twice, each with --fresh and the same VERSION and
#   SOURCE_DATE_EPOCH, then compares the layer images, the ISO, the UKIs and
#   the distrobox OCI layout. The second run uses the repository metadata of
#   the first (--cache-only=metadata), so package updates in between are not
#   counted as differences. Mismatches are listed by sha256, with a diffoscope
#   report per file when diffoscope is installed.

set -euo pipefail

root="$(git rev-parse --show-toplevel)"
# shellcheck source=lib/log.sh
source "$root/lib/log.sh"
edition="${1:-mokka}"

if [[ ! -d "$root/mkosi.images/desktop/mkosi.profiles/$edition" ]]; then
  echo "unknown edition $edition, see scripts/editions.sh" >&2
  exit 1
fi

# SOURCE_DATE_EPOCH is the HEAD commit time, so HEAD must not move
export VERSION="${VERSION:-$(date +%Y%m%d)}"
head="$(git -C "$root" rev-parse HEAD)"
out="$root/mkosi.output"
work="$root/mkosi.cache/repro"

# mkosi.cache belongs to root
sudo install -d -o "$(id -u)" -g "$(id -g)" "$work"
rm -rf "$work/a" "$work/b" "$work/diffoscope"

build_all() {
  "$root/scripts/build.sh" --fresh iso "$edition" "$@"
  "$root/scripts/build.sh" --fresh uki "$@"
  "$root/scripts/build.sh" --fresh distrobox "$@"
}

# As root: some outputs are root-only, for example the verity files of
# veritysetup. The copies then go to the user.
collect() {
  local dest="$work/$1" layer uki

  mkdir -p "$dest/layers"
  for layer in root desktop drivers live; do
    sudo cp "$out/.erofs/$layer".{erofs,verity,roothash} "$dest/layers/"
  done

  sudo cp "$(readlink -f "$out/garuda-$edition.iso")" "$dest/garuda-$edition.iso"
  for uki in "$out"/garuda-*-"$VERSION".efi "$out"/garuda-*-"$VERSION"-eac.efi; do
    sudo cp "$uki" "$dest/"
  done

  sudo cp -a "$out/garuda-distrobox" "$dest/oci"
  sudo chown -R "$(id -u):$(id -g)" "$dest"
}

checksums() {
  (cd "$work/$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) >"$work/$1.sha256"
}

log "First run (VERSION=$VERSION)"
build_all
collect a

log "Second run, with the repository metadata of the first"
build_all --cache-only=metadata
collect b

if [[ "$(git -C "$root" rev-parse HEAD)" != "$head" ]]; then
  echo "HEAD moved from ${head:0:7} during the check, run it again" >&2
  exit 2
fi

checksums a
checksums b

mapfile -t differ < <(join -j 2 <(sort -k2 "$work/a.sha256") <(sort -k2 "$work/b.sha256") |
  awk '$2 != $3 { print $1 }')

if ((${#differ[@]} == 0)) && cmp -s <(cut -d' ' -f3 "$work/a.sha256") <(cut -d' ' -f3 "$work/b.sha256"); then
  echo "Reproducible: both runs gave the same $(wc -l <"$work/a.sha256") files"
  exit 0
fi

echo "Not reproducible. Differing files:"
printf '  %s\n' "${differ[@]}"
diff <(cut -d' ' -f3 "$work/a.sha256") <(cut -d' ' -f3 "$work/b.sha256") || true

if command -v diffoscope >/dev/null; then
  mkdir -p "$work/diffoscope"
  for file in "${differ[@]}"; do
    report="$work/diffoscope/$(tr '/' '_' <<<"${file#./}").html"
    diffoscope --html "$report" "$work/a/$file" "$work/b/$file" >/dev/null || true
    echo "  $report"
  done
else
  echo "Install diffoscope for a report per file, for example: nix run nixpkgs#diffoscope -- $work/a/<file> $work/b/<file>"
fi

exit 1
