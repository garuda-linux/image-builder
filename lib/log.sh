# shellcheck shell=bash
# Status lines in the style of mkosi and makepkg

log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==> WARNING:\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[1;31m==> ERROR:\033[0m %s\n' "$*" >&2
  exit 1
}
