# shellcheck shell=bash
# OCI images with base as the shared first layer and the image tree's changes as
# the second. mkosi only writes single-layer OCI images.

readonly OCI_SOURCE=https://gitlab.com/garuda-linux/tools/image-builder

# Prints "<digest> <diff_id>". Sorted and with clamped mtimes, so a tree always gives the same blob.
oci_layer() {
  local dir="$1" blobs="$2" tar digest diff_id

  tar="$(mktemp "$blobs/.layer.XXXXXX")"
  tar --create --file "$tar" --directory "$dir" \
    --sort=name --numeric-owner \
    --mtime="@$SOURCE_DATE_EPOCH" --clamp-mtime \
    --acls --xattrs \
    --pax-option=delete=atime,delete=ctime,delete=mtime \
    --sparse --anchored \
    --exclude './dev/*' --exclude './proc/*' --exclude './sys/*' \
    --exclude './tmp/*' --exclude './run/*' --exclude './var/tmp/*' \
    .
  diff_id="$(sha256sum "$tar" | cut -d' ' -f1)"
  zstd -q -3 -T0 --rm "$tar" -o "$tar.zst"
  digest="$(sha256sum "$tar.zst" | cut -d' ' -f1)"
  chmod 0644 "$tar.zst"
  mv "$tar.zst" "$blobs/$digest"
  echo "$digest $diff_id"
}

# Cached per base stamp and package list: a package update rebuild keeps the stamp
oci_base_layer() {
  local blobs="$1" cache="$OUTPUT_DIR/.oci-cache" key ids

  key="$({
    echo "${NEW_STAMP[base]}" "$SOURCE_DATE_EPOCH"
    printf '%s\n' "$OUTPUT_DIR"/base/var/lib/pacman/local/*
  } | sha256sum | cut -d' ' -f1)"

  if [[ -z "${REBUILT[base]:-}" && -f "$cache/base.blob" && -f "$cache/base.ids" &&
    "$(cat "$cache/base.key" 2>/dev/null)" == "$key" ]]; then
    log "Reusing the base layer blob" >&2
    ids="$(cat "$cache/base.ids")"
  else
    remove_output "$cache"
    mkdir -p "$cache"
    ids="$(oci_layer "$OUTPUT_DIR/base" "$cache")"
    mv "$cache/${ids%% *}" "$cache/base.blob"
    echo "$ids" >"$cache/base.ids"
    echo "$key" >"$cache/base.key"
  fi

  cp --reflink=auto "$cache/base.blob" "$blobs/${ids%% *}"
  echo "$ids"
}

# A deleted path needs no whiteout when a parent is deleted too, or when the
# upper tree replaced a parent directory with a file or symlink
oci_under_whiteout() {
  local out="$1" upper="$2" path="$3"
  while [[ "$path" == */* ]]; do
    path="${path%/*}"
    [[ -e "$out/${path%/*}/.wh.${path##*/}" ]] && return 0
    [[ -L "$upper/$path" || ! -d "$upper/$path" ]] && return 0
  done

  return 1
}

# Changed files of upper plus a whiteout (.wh.<name>) per deleted path. --checksum:
# mkosi clamps every mtime, so size and time cannot tell changed files apart.
oci_diff() {
  local lower="$1" upper="$2" out="$3" path

  mkdir -p "$out"
  rsync -aHAX --checksum --checksum-choice=xxh3 --compare-dest="$lower/" "$upper/" "$out/"

  while IFS= read -r path; do
    oci_under_whiteout "$out" "$upper" "$path" && continue
    mkdir -p "$out/${path%/*}"
    : >"$out/${path%/*}/.wh.${path##*/}"
  done < <(LC_ALL=C comm -23 \
    <(cd "$lower" && find . -mindepth 1 | LC_ALL=C sort) \
    <(cd "$upper" && find . -mindepth 1 | LC_ALL=C sort))
}

# oci_image <name> <cmd> <title> <description> [label=value ...]
# Packs $OUTPUT_DIR/garuda-<name>-tree into the OCI layout $OUTPUT_DIR/garuda-<name>
oci_image() {
  local name="$1" cmd="$2" title="$3" description="$4"
  shift 4
  local tree="$OUTPUT_DIR/garuda-$name-tree" dir="$OUTPUT_DIR/garuda-$name"
  local work="$OUTPUT_DIR/.oci-work" blobs created base top labels label config manifest

  remove_output "$dir" "$work"
  blobs="$dir/blobs/sha256"
  mkdir -p "$blobs" "$work"

  read -r -a base <<<"$(oci_base_layer "$blobs")"
  oci_diff "$OUTPUT_DIR/base" "$tree" "$work/diff"
  read -r -a top <<<"$(oci_layer "$work/diff" "$blobs")"
  remove_output "$work"

  labels='{}'
  for label in "name=garuda-$name" "$@"; do
    labels="$(jq -c --arg k "${label%%=*}" --arg v "${label#*=}" '. + {($k): $v}' <<<"$labels")"
  done

  created="$(date -u -d "@$SOURCE_DATE_EPOCH" +%Y-%m-%dT%H:%M:%SZ)"
  config="$(oci_write_blob "$blobs" "$(jq -nc --arg created "$created" --arg cmd "$cmd" --argjson labels "$labels" \
    --arg base "sha256:${base[1]}" --arg top "sha256:${top[1]}" --arg name "garuda-$name" '{
      created: $created, architecture: "amd64", os: "linux",
      config: {Cmd: [$cmd], Labels: $labels},
      rootfs: {type: "layers", diff_ids: [$base, $top]},
      history: [{created: $created, comment: "base"}, {created: $created, comment: $name}]
    }')")"

  manifest="$(oci_write_blob "$blobs" "$(jq -nc \
    --arg config "$config" --argjson config_size "$(stat -c %s "$blobs/$config")" \
    --arg base "${base[0]}" --argjson base_size "$(stat -c %s "$blobs/${base[0]}")" \
    --arg top "${top[0]}" --argjson top_size "$(stat -c %s "$blobs/${top[0]}")" \
    --arg version "$VERSION" --arg title "$title" --arg description "$description" --arg source "$OCI_SOURCE" '{
      schemaVersion: 2,
      mediaType: "application/vnd.oci.image.manifest.v1+json",
      config: {mediaType: "application/vnd.oci.image.config.v1+json", digest: ("sha256:" + $config), size: $config_size},
      layers: [
        {mediaType: "application/vnd.oci.image.layer.v1.tar+zstd", digest: ("sha256:" + $base), size: $base_size},
        {mediaType: "application/vnd.oci.image.layer.v1.tar+zstd", digest: ("sha256:" + $top), size: $top_size}
      ],
      annotations: {
        "org.opencontainers.image.version": $version,
        "org.opencontainers.image.title": $title,
        "org.opencontainers.image.description": $description,
        "org.opencontainers.image.source": $source,
        "org.opencontainers.image.vendor": "Garuda Linux"
      }
    }')")"

  jq -nc --arg manifest "$manifest" --argjson size "$(stat -c %s "$blobs/$manifest")" '{
    schemaVersion: 2,
    mediaType: "application/vnd.oci.image.index.v1+json",
    manifests: [{mediaType: "application/vnd.oci.image.manifest.v1+json", digest: ("sha256:" + $manifest), size: $size,
      annotations: {"org.opencontainers.image.ref.name": "garuda"}}]
  }' >"$dir/index.json"
  printf '{"imageLayoutVersion":"1.0.0"}' >"$dir/oci-layout"

  mv "$tree.manifest" "$dir.manifest"
  remove_output "$tree"
}

oci_write_blob() {
  local blobs="$1" json="$2" tmp digest
  tmp="$(mktemp "$blobs/.blob.XXXXXX")"
  printf '%s' "$json" >"$tmp"
  digest="$(sha256sum "$tmp" | cut -d' ' -f1)"
  chmod 0644 "$tmp"
  mv "$tmp" "$blobs/$digest"
  echo "$digest"
}
