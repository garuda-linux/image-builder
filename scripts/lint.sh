#!/usr/bin/env bash

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
status=0

ok() { printf '  \033[1;32mok\033[0m    %s\n' "$1"; }
fail() {
  printf '  \033[1;31mfail\033[0m  %s\n' "$1"
  status=1
}

if command -v prek >/dev/null; then
  prek run --all-files || status=1
else
  echo "prek not found, pre-commit hooks skipped (they run in the development shell)"
fi

# An assignment, not mapfile < <(...): only an assignment fails when the script fails
scripts_out="$(scripts/shell-files.sh)" || fail "shell file list"
mapfile -t scripts <<<"$scripts_out"

# Scripts that mkosi or systemd run directly need the executable bit in git,
# mkosi stops on a postinst script without it
nonexec="$(git ls-files -s -- '*.chroot' 'mkosi.images/*/mkosi.extra/usr/bin/*' \
  'mkosi.images/*/mkosi.extra/usr/lib/garuda/*' \
  'mkosi.images/*/mkosi.extra/usr/lib/systemd/system-generators/*' | awk '$1 == "100644" { print $4 }')"
if [[ -z "$nonexec" ]]; then ok "executable bits"; else
  fail "executable bits"
  while read -r path; do
    echo "          not executable: $path"
  done <<<"$nonexec"
fi

if shellcheck -x "${scripts[@]}"; then ok "shellcheck"; else fail "shellcheck"; fi
if shfmt -d "${scripts[@]}"; then ok "shfmt"; else fail "shfmt"; fi

if command -v ruff >/dev/null; then
  mapfile -t python < <(git ls-files '*.py')
  if ruff check "${python[@]}"; then ok "ruff check"; else fail "ruff check"; fi
  if ruff format --check "${python[@]}"; then ok "ruff format"; else fail "ruff format"; fi
else
  echo "ruff not found, Python checks skipped (it is in the development shell and the builder image)"
fi

if command -v yamllint >/dev/null; then
  # Tracked files only: the build output holds YAML files too
  mapfile -t yaml < <(git ls-files '*.yml' '*.yaml' .yamllint)
  if yamllint "${yaml[@]}"; then ok "yamllint"; else fail "yamllint"; fi
else
  echo "yamllint not found, YAML checks skipped (it is in the development shell and the builder image)"
fi

# ci/Containerfile installs from the archive snapshot of its FROM tag. Renovate
# bumps the tag and ARCH_SNAPSHOT together. A mismatch either builds against a
# different snapshot or fails when the archive does not have the package DB.
from_snapshot="$(sed -n 's|^FROM .*archlinux:base-\([0-9]\{8\}\).*|\1|p' ci/Containerfile)"
arg_snapshot="$(sed -n 's|^ARG ARCH_SNAPSHOT=\([0-9]\{4\}\)/\([0-9]\{2\}\)/\([0-9]\{2\}\)$|\1\2\3|p' ci/Containerfile)"
if [[ -n "$from_snapshot" && "$from_snapshot" == "$arg_snapshot" ]]; then
  ok "builder image snapshot"
else
  fail "builder image snapshot"
  echo "          FROM tag date ${from_snapshot:-none} does not match ARCH_SNAPSHOT ${arg_snapshot:-none}"
fi

if command -v hadolint >/dev/null; then
  if hadolint ci/Containerfile ci/openqa.Containerfile ci/openqa-client.Containerfile; then ok "hadolint"; else fail "hadolint"; fi
else
  echo "hadolint not found, Containerfile checks skipped (it is in the development shell and flake-check)"
fi

# Layers only match when build.sh marks them for a build, see lib/layers.sh
all_layers=()
for layer in BASE ROOT DESKTOP LIVE DRIVERS LIVE_INITRD; do
  all_layers+=(--environment="GARUDA_BUILD_$layer=1")
done

editions_out="$(scripts/editions.sh)" || fail "edition list"
mapfile -t editions <<<"$editions_out"

# The editions input of .gitlab-ci.yml lists them for the Run pipeline form
input_options="$(sed -n '/^    editions:$/,/^    [a-z_]*:$/s/^        - //p' .gitlab-ci.yml | paste -sd' ' -)"
listed="all ${editions[*]}"
if [[ "$input_options" == "$listed" ]]; then ok "editions input"; else
  fail "editions input"
  echo "          .gitlab-ci.yml: ${input_options:-none}"
  echo "          scripts/editions.sh: $listed"
fi

mkdir -p mkosi.packages
for profiles in distrobox oci lima uki "${editions[@]/#/iso,}" "${editions[@]/#/vm,}"; do
  if errors="$(mkosi --profile "$profiles" "${all_layers[@]}" summary 2>&1 >/dev/null)"; then
    ok "mkosi --profile $profiles"
  else
    fail "mkosi --profile $profiles"
    printf '%s\n' "$errors" | sed 's/^/          /'
  fi
done

exit "$status"
