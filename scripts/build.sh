#!/usr/bin/env bash
# Runs build.sh in the builder container, from anywhere in the checkout.
# `build pkg ...` runs scripts/local-pkg.sh instead, as the user: cpb needs rootless podman.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
if [[ "${1:-}" == pkg ]]; then
  shift
  exec bash scripts/local-pkg.sh "$@"
fi

# SOURCE_DATE_EPOCH is not passed on: the Nix shell sets it to 1980
exec sudo --preserve-env=VERSION,ISO_COMPRESSION,BUILDER_UPDATE,SB_KEY,SB_CERT,SB_CA_CERT ./build.sh --container "$@"
