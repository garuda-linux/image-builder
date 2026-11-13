#!/bin/sh
# Usage: ci/cosign-blob.sh <file>
#   Signs <file> with cosign in keyless mode (SIGSTORE_ID_TOKEN), writes
#   <file>.sigstore.json and verifies it. See docs/ci.md.

set -eu

file="${1:?usage: ci/cosign-blob.sh <file>}"
bundle="$file.sigstore.json"

[ -f "$file" ] || {
  echo "$file is missing" >&2
  exit 1
}

# The certificate names the top-level pipeline definition (ci_config_ref_uri of
# the ID token), also for a child pipeline job
[ -n "${SIGSTORE_ID_TOKEN:-}" ] || {
  echo "SIGSTORE_ID_TOKEN is not set, the job needs id_tokens with the audience sigstore" >&2
  exit 1
}

if [ -n "${CI_COMMIT_TAG:-}" ]; then
  ref="refs/tags/$CI_COMMIT_TAG"
else
  ref="refs/heads/${CI_COMMIT_BRANCH:?neither CI_COMMIT_TAG nor CI_COMMIT_BRANCH is set}"
fi

attempt=1
until cosign sign-blob --yes --identity-token "$SIGSTORE_ID_TOKEN" --bundle "$bundle" "$file"; do
  if [ "$attempt" -ge 5 ]; then
    echo "Signing ${file##*/} failed 5 times" >&2
    exit 1
  fi
  echo "Signing failed (attempt $attempt of 5), retrying in 30 seconds"
  attempt=$((attempt + 1))
  sleep 30
done

cosign verify-blob --bundle "$bundle" \
  --certificate-identity "$CI_PROJECT_URL//.gitlab-ci.yml@$ref" \
  --certificate-oidc-issuer "$CI_SERVER_URL" "$file"
