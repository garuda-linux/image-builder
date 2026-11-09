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

# Scripts that mkosi, pacman, kernel-install or systemd run directly need the
# executable bit in git, mkosi stops on a postinst script without it
nonexec="$(git ls-files -s -- '*.chroot' '*.install' 'mkosi.images/*/mkosi.extra/usr/bin/*' \
  'mkosi.images/*/mkosi.extra/usr/lib/garuda/*' 'mkosi.images/*/mkosi.extra/usr/lib/snapper/plugins/*' \
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

# Layers only match when build.sh marks them for a build, see lib/layers.sh
all_layers=()
for layer in BASE ROOT DESKTOP LIVE MHWD LIVE_INITRD; do
  all_layers+=(--environment="GARUDA_BUILD_$layer=1")
done

editions_out="$(scripts/editions.sh)" || fail "edition list"
mapfile -t editions <<<"$editions_out"
for profiles in distrobox lima uki "${editions[@]/#/iso,}" "${editions[@]/#/vm,}"; do
  if errors="$(mkosi --profile "$profiles" "${all_layers[@]}" summary 2>&1 >/dev/null)"; then
    ok "mkosi --profile $profiles"
  else
    fail "mkosi --profile $profiles"
    printf '%s\n' "$errors" | sed 's/^/          /'
  fi
done

exit "$status"
