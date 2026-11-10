#!/bin/sh
# Usage: ci/shared-state.sh
#   Bind-mounts mkosi.output and mkosi.cache from /cache/image-builder/<pipeline>/,
#   so the build jobs of one pipeline, its ISO child pipeline included, share
#   layers, packages and caches. The jobs run one at a time (resource_group
#   build-host), so they never write at once.
#   mkosi.tools is not shared: mkosi removes it as a whole when it rebuilds the
#   tools tree, which a mount point does not allow.

set -eu

# The ISO child pipeline gets the id of its parent, see the iso job
pipeline="${IB_PIPELINE_ID:-$CI_PIPELINE_ID}"
base=/cache/image-builder

mkdir -p "$base"

# Pipelines two days or older, also cancelled ones
find "$base" -mindepth 1 -maxdepth 1 -type d ! -name "$pipeline" -mtime +1 -exec rm -rf {} + 2>/dev/null || true

for dir in mkosi.output mkosi.cache; do
  mkdir -p "$base/$pipeline/$dir" "$dir"
  mount --bind "$base/$pipeline/$dir" "$dir"
done
touch "$base/$pipeline"

echo "Sharing mkosi.output and mkosi.cache with pipeline $pipeline: $(du -sh "$base/$pipeline" | cut -f1)"
