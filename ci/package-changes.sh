#!/usr/bin/env bash
# Writes <manifest>.changes against the last successful build of the job on the
# default branch. Never fails the job.
# Usage: ci/package-changes.sh <job name> <manifest>

set -uo pipefail

job="$1" manifest="$2"
previous="$(mktemp)"
trap 'rm -f "$previous"' EXIT

url="$CI_API_V4_URL/projects/$CI_PROJECT_ID/jobs/artifacts/$CI_DEFAULT_BRANCH/raw/$manifest?job=$(printf '%s' "$job" | sed 's/:/%3A/g')"
if curl --fail --silent --show-error --location --header "JOB-TOKEN: $CI_JOB_TOKEN" \
  --output "$previous" "$url"; then
  # A failing diff leaves its error message in .changes, not an empty file
  scripts/manifest_diff.py "$previous" "$manifest" >"$manifest.changes" 2>&1 ||
    echo "(manifest-diff failed, the package changes are unknown)" >>"$manifest.changes"
  cat "$manifest.changes"
else
  echo "No previous manifest of $job on $CI_DEFAULT_BRANCH, first build" | tee "$manifest.changes"
fi

exit 0
