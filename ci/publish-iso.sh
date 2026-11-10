#!/bin/sh
# Usage: ci/publish-iso.sh <edition>
#   Publishes the ISO of <edition> with its checksum, manifest and SBOM to
#   /publish/iso/<edition>/<kind>/, the image-builder tree of
#   iso.builds.garudalinux.org that the runner mounts. <kind> is release for a
#   date tag (YYYYMMDD) and latest for the default branch. Each kind keeps one
#   build: a new upload replaces the whole directory.

set -eu

edition="${1:?usage: ci/publish-iso.sh <edition>}"
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

iso="$(readlink -f "mkosi.output/garuda-$edition.iso")"
name="${iso##*/}"
for file in "$iso" "$iso.sha256" "mkosi.output/garuda-$edition.iso.manifest" "mkosi.output/garuda-$edition.iso.spdx.json"; do
  [ -f "$file" ] || {
    echo "$file is missing" >&2
    exit 1
  }
done

# Uploaded next to the old build, then swapped, so the old one stays complete
# until the new one is available.
dir="$dest/$edition/$kind"
tmp="$dest/$edition/.$kind.new"
rm -rf "$tmp"
mkdir -p "$tmp"
rsync --times --chmod=D755,F644 "$iso" "$iso.sha256" "$tmp/"
rsync --times --chmod=F644 "mkosi.output/garuda-$edition.iso.manifest" "$tmp/$name.manifest"
rsync --times --chmod=F644 "mkosi.output/garuda-$edition.iso.spdx.json" "$tmp/$name.spdx.json"
rm -rf "$dir"
mv "$tmp" "$dir"

echo "Published $name as the $kind ISO of $edition: https://iso.builds.garudalinux.org/iso/image-builder/$edition/$kind/$name"
