# shellcheck shell=bash
# The OCI layout of the distrobox output. mkosi has no setting for the Entrypoint.

# Writes a JSON blob into the layout and prints its digest
oci_write_blob() {
  local blobs="$1" json="$2" tmp digest
  tmp="$(mktemp "$blobs/.blob.XXXXXX")"
  printf '%s' "$json" >"$tmp"
  digest="$(sha256sum "$tmp" | cut -d' ' -f1)"
  chmod 0644 "$tmp"
  mv "$tmp" "$blobs/$digest"
  echo "$digest"
}

oci_set_entrypoint() {
  local dir="$1" entrypoint="$2" blobs="$1/blobs/sha256"
  local manifest config new_config new_manifest

  [[ "$(jq '.manifests | length' "$dir/index.json")" == 1 ]] || die "$dir: expected one manifest in index.json"
  manifest="$(jq -r '.manifests[0].digest | ltrimstr("sha256:")' "$dir/index.json")"
  config="$(jq -r '.config.digest | ltrimstr("sha256:")' "$blobs/$manifest")"

  new_config="$(oci_write_blob "$blobs" "$(jq -c --arg e "$entrypoint" '.config.Entrypoint = [$e]' "$blobs/$config")")"
  new_manifest="$(oci_write_blob "$blobs" "$(jq -c --arg d "sha256:$new_config" --argjson s "$(stat -c %s "$blobs/$new_config")" \
    '.config.digest = $d | .config.size = $s' "$blobs/$manifest")")"
  jq -c --arg d "sha256:$new_manifest" --argjson s "$(stat -c %s "$blobs/$new_manifest")" \
    '.manifests[0].digest = $d | .manifests[0].size = $s' "$dir/index.json" >"$dir/index.json.new"
  mv "$dir/index.json.new" "$dir/index.json"

  [[ "$config" == "$new_config" ]] || rm -f "$blobs/$config"
  [[ "$manifest" == "$new_manifest" ]] || rm -f "$blobs/$manifest"
}
