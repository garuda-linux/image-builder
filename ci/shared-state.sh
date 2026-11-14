#!/bin/sh
# Usage: ci/shared-state.sh [save-tools|prune]
#   Links mkosi.output, mkosi.cache and mkosi.workspace to /cache/image-builder/,
#   shared by all pipelines. Jobs run one at a time (resource_group build-host).
#   The tools tree is /cache/image-builder-tools/, replaced when its key changes.
#   prune removes final images, uninstalled packages, older release caches and
#   publish stages older than a day.

set -eu

base=/cache/image-builder
tools=/cache/image-builder-tools

if [ "${1:-}" = prune ]; then
  # Small artifact files stay: GitLab uploads them after after_script
  find "$base/mkosi.output" -mindepth 1 -maxdepth 1 \( -name 'garuda-*.iso' -o -name 'garuda-*.qcow2' \
    -o -name 'garuda-*.efi' -o -name garuda-distrobox -o -name garuda-oci -o -name 'garuda-*-tree' -o -name .oci-work \) -exec rm -rf {} +

  installed="$(mktemp)"
  for db in "$base"/mkosi.output/*/var/lib/pacman/local "$base"/mkosi.cache/*.cache/var/lib/pacman/local \
    mkosi.tools/var/lib/pacman/local; do
    [ -d "$db" ] && ls "$db"
  done | sort -u >"$installed"

  for file in "$base"/mkosi.cache/packages/cache/pacman/pkg/*.pkg.tar*; do
    [ -e "$file" ] || continue
    id="${file##*/}"
    id="${id%.sig}"
    id="${id%.pkg.tar*}"
    grep -qxF "${id%-*}" "$installed" || rm -f "$file"
  done

  rm -f "$installed"
  find /cache/publish -mindepth 2 -maxdepth 2 -type d -mmin +1440 -exec rm -rf {} + 2>/dev/null || true

  # <distribution>~<release>~<arch>~<image>: keep the newest release
  newest="$(find "$base/mkosi.cache" -mindepth 1 -maxdepth 1 -name '*~*.cache' -printf '%T@ %p\n' 2>/dev/null |
    sort -n | tail -n1 | cut -d' ' -f2-)"
  if [ -n "$newest" ]; then
    release="${newest##*/}"
    release="${release#*~}"
    release="${release%%~*}"
    for entry in "$base"/mkosi.cache/*~*; do
      name="${entry##*/}"
      name="${name#*~}"
      [ "${name%%~*}" = "$release" ] || rm -rf "$entry"
    done
  fi

  shim="$(sed -n 's/^readonly SHIM_VERSION="\(.*\)"/\1/p' lib/secureboot.sh)"
  for file in "$base"/mkosi.cache/shim/*; do
    [ -e "$file" ] || continue
    case "${file##*/}" in
      *"-$shim."*) ;;
      *) rm -f "$file" ;;
    esac
  done

  echo "Pruned the shared state: $(du -sh "$base" | cut -f1)"
  exit 0
fi
key="$({
  cat mkosi.conf mkosi.conf.d/*.conf
  mkosi --version
} | sha256sum | cut -c1-16)"

if [ "${1:-}" = save-tools ]; then
  if [ -d mkosi.tools ] && [ ! -L mkosi.tools ] && [ -f mkosi.tools.manifest ]; then
    rm -rf "$tools.new"
    mkdir -p "$tools.new"
    cp -a --reflink=auto mkosi.tools mkosi.tools.manifest "$tools.new/"
    echo "$key" >"$tools.new/key"
    rm -rf "$tools"
    mv "$tools.new" "$tools"
    echo "Saved the tools tree $key for later jobs"
  fi

  exit 0
fi

# mkosi.workspace too: mkosi renames finished images from it into
# mkosi.output, which needs both on one device, or it copies every layer
for dir in mkosi.output mkosi.cache mkosi.workspace; do
  mkdir -p "$base/$dir"
  [ -L "$dir" ] || rm -rf -- "$dir"
  ln -sfn "$base/$dir" "$dir"
done

# The artifact files prune left
find "$base/mkosi.output" -mindepth 1 -maxdepth 1 -name 'garuda-*' -exec rm -rf {} +

if [ "$(cat "$tools/key" 2>/dev/null)" = "$key" ]; then
  for path in mkosi.tools mkosi.tools.manifest; do
    [ -L "$path" ] || rm -rf -- "$path"
    ln -sfn "$tools/$path" "$path"
  done

  echo "Reusing the tools tree $key"
fi

echo "Sharing mkosi.output, mkosi.cache and mkosi.workspace: $(du -sh "$base" | cut -f1)"
