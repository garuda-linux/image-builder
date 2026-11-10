#!/bin/sh
# Usage: ci/shared-state.sh [save-tools]
#   Links mkosi.output and mkosi.cache to /cache/image-builder/<pipeline>/,
#   so the build jobs of one pipeline, its ISO child pipeline included, share
#   layers, packages and caches. The jobs run one at a time (resource_group
#   build-host), so they never write at once.
#
#   The tools tree only depends on the tools settings (ToolsTreeSnapshot= and
#   the package list) and the mkosi version, so all pipelines share it, under
#   /cache/image-builder-tools/<key>/.

set -eu

tools_base=/cache/image-builder-tools
tools_key="$({
  cat mkosi.conf mkosi.conf.d/*.conf
  mkosi --version
} | sha256sum | cut -c1-16)"
tools="$tools_base/$tools_key"

if [ "${1:-}" = save-tools ]; then
  if [ -d mkosi.tools ] && [ ! -L mkosi.tools ] && [ -f mkosi.tools.manifest ]; then
    rm -rf "$tools.new"
    mkdir -p "$tools.new"
    cp -a --reflink=auto mkosi.tools mkosi.tools.manifest "$tools.new/"
    rm -rf "$tools"
    mv "$tools.new" "$tools"
    echo "Saved the tools tree as $tools_key for later jobs"
  fi

  exit 0
fi

# The ISO child pipeline gets the id of its parent, see the iso job
pipeline="${IB_PIPELINE_ID:-$CI_PIPELINE_ID}"
base=/cache/image-builder

mkdir -p "$base" "$tools_base"

# Pipelines two days or older, also cancelled ones. Tools trees unused for a week.
find "$base" -mindepth 1 -maxdepth 1 -type d ! -name "$pipeline" -mtime +1 -exec rm -rf {} + 2>/dev/null || true
find "$tools_base" -mindepth 1 -maxdepth 1 -type d ! -name "$tools_key" -mtime +7 -exec rm -rf {} + 2>/dev/null || true

for dir in mkosi.output mkosi.cache; do
  mkdir -p "$base/$pipeline/$dir"
  [ -L "$dir" ] || rm -rf -- "$dir"
  ln -sfn "$base/$pipeline/$dir" "$dir"
done
touch "$base/$pipeline"

if [ -d "$tools/mkosi.tools" ] && [ -f "$tools/mkosi.tools.manifest" ]; then
  for path in mkosi.tools mkosi.tools.manifest; do
    [ -L "$path" ] || rm -rf -- "$path"
    ln -sfn "$tools/$path" "$path"
  done

  touch "$tools"
  echo "Reusing the tools tree $tools_key"
fi

echo "Sharing mkosi.output and mkosi.cache with pipeline $pipeline: $(du -sh "$base/$pipeline" | cut -f1)"
