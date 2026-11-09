#!/usr/bin/env bash
# Runs build.sh in the builder container, from anywhere in the checkout.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
# SOURCE_DATE_EPOCH is not passed on: the Nix shell sets it to 1980
exec sudo --preserve-env=VERSION,ISO_COMPRESSION,SB_KEY,SB_CERT,SB_CA_CERT ./build.sh --container "$@"
