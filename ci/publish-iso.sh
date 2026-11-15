#!/bin/sh
# Usage: ci/publish-iso.sh <edition> [<dir>]
#   Publishes the ISO of <edition> in <dir> (default mkosi.output) with its
#   checksum, manifest, SBOM and stamp (see ci/iso_pipeline.py) to
#   /publish/iso/<edition>/<kind>/, the image-builder tree of
#   iso.builds.garudalinux.org that the runner mounts. <kind> is release for a
#   date tag (YYYYMMDD) and latest for the default branch. Each kind keeps one
#   build: a new upload replaces the whole directory.
#   The checksum is signed with cosign in keyless mode, see docs/ci.md.

set -eu

edition="${1:?usage: ci/publish-iso.sh <edition> [<dir>]}"
src="${2:-mkosi.output}"
dest=/publish/iso

if [ -n "${CI_COMMIT_TAG:-}" ]; then
  if ! printf '%s\n' "$CI_COMMIT_TAG" | grep -qx '[0-9]\{8\}'; then
    echo "Tag $CI_COMMIT_TAG is not a release date (YYYYMMDD), the ISO is not published"
    exit 0
  fi
  kind=release
elif [ -n "${CI_COMMIT_BRANCH:-}" ] && [ "$CI_COMMIT_BRANCH" = "${CI_DEFAULT_BRANCH:-}" ]; then
  kind=latest
else
  echo "Not the default branch or a tag, the ISO is not published"
  exit 0
fi

# The runner mounts it, see stormwing-nix-privileged in infra-nix
[ -d "$dest" ] || {
  echo "$dest is not mounted, cannot publish the ISO" >&2
  exit 1
}

[ -d "$src" ] || {
  echo "$src does not exist, nothing to publish" >&2
  exit 1
}

iso="$(readlink -f "$src/garuda-$edition.iso")"
name="${iso##*/}"
for file in "$iso" "$iso.sha256" "$src/garuda-$edition.iso.manifest" "$src/garuda-$edition.iso.spdx.json"; do
  [ -f "$file" ] || {
    echo "$file is missing" >&2
    exit 1
  }
done

bundle="$iso.sha256.sigstore.json"
"$(dirname "$0")/cosign-blob.sh" "$iso.sha256"

# Uploaded next to the old build, then swapped, so the old one stays complete
# until the new one is available.
dir="$dest/$edition/$kind"
tmp="$dest/$edition/.$kind.new"
rm -rf "$tmp"
mkdir -p "$tmp"
cp --reflink=auto --preserve=timestamps "$iso" "$iso.sha256" "$bundle" "$tmp/"
chmod 644 "$tmp"/*

if [ "$kind" = release ]; then
  path="image-builder/$edition/release/$name"
  mktorrent -l 22 \
    -a udp://tracker.opentrackr.org:1337/announce \
    -a udp://open.stealth.si:80/announce \
    -a udp://tracker.torrent.eu.org:451/announce \
    -a udp://open.demonii.com:1337/announce \
    -w "https://r2.garudalinux.org/iso/$path,https://downloads.sourceforge.net/project/garuda-linux/$path,https://iso.builds.garudalinux.org/iso/$path" \
    -o "$tmp/$name.torrent" "$iso"
  chmod 644 "$tmp/$name.torrent"
fi

rsync --times --chmod=F644 "$src/garuda-$edition.iso.manifest" "$tmp/$name.manifest"
rsync --times --chmod=F644 "$src/garuda-$edition.iso.spdx.json" "$tmp/$name.spdx.json"
# Fixed name, fetched by ci/iso_pipeline.py
if [ -f "$src/garuda-$edition.stamp" ]; then
  rsync --times --chmod=F644 "$src/garuda-$edition.stamp" "$tmp/"
fi
rm -rf "$dir"
mv "$tmp" "$dir"

echo "Published $name as the $kind ISO of $edition: https://iso.builds.garudalinux.org/iso/image-builder/$edition/$kind/$name"
