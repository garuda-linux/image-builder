# shellcheck shell=bash
# Built images in mkosi.output by edition and version. Needs lib/log.sh.

# image_path <root> iso|vm <edition> [version]: the newest image, or the one of
# that version (YYYYMMDD)
image_path() {
  local kind="$2" edition="$3" version="${4:-}" out="$1/mkosi.output" matches=()

  if [[ -z "$version" ]]; then
    local link="$out/garuda-$edition.iso"
    [[ "$kind" == iso ]] || link="$out/garuda-vm-$edition.qcow2"
    [[ -e "$link" ]] || die "no $kind image of $edition at $link, run: build $kind $edition"

    readlink -f "$link"
    return
  fi

  [[ "$version" =~ ^[0-9]{8}$ ]] || die "version must be a date as YYYYMMDD, not $version"

  # garuda-<edition>-<kernel>-<version>.iso. The kernel package starts with linux,
  # so dr460nized does not match dr460nized-gaming.
  if [[ "$kind" == iso ]]; then
    mapfile -t matches < <(compgen -G "$out/garuda-$edition-linux*-$version.iso")
  else
    mapfile -t matches < <(compgen -G "$out/garuda-vm-$edition-$version.qcow2")
  fi

  ((${#matches[@]} == 1)) || die "no single $kind image of $edition for version $version in $out, see: build ls"
  echo "${matches[0]}"
}

# iso_versions <root> <edition>: the versions of the ISOs with a manifest, oldest first
iso_versions() {
  local file

  for file in "$1/mkosi.output/garuda-$2"-linux*-20[0-9][0-9][0-9][0-9][0-9][0-9].iso.manifest; do
    [[ -f "$file" ]] || continue

    file="${file%.iso.manifest}"
    echo "${file##*-}"
  done | sort -u
}

# esp_offset <iso>: the byte offset of the ESP, for mtools -i <iso>@@<offset>
esp_offset() {
  local offset
  offset="$(sfdisk --json "$1" | jq -r '.partitiontable as $t | $t.partitions[]
    | select(.type == "C12A7328-F81F-11D2-BA4B-00A0C93EC93B") | .start * ($t.sectorsize // 512)')"
  [[ "$offset" =~ ^[0-9]+$ ]] || die "no ESP found in $1"

  echo "$offset"
}
