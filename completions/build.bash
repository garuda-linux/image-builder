_garuda_build_pkg() {
  local start="$1" root="$2" cur="${COMP_WORDS[COMP_CWORD]}" prev="${COMP_WORDS[COMP_CWORD - 1]}"
  local pkgbuilds="${GARUDA_PKGBUILDS:-$root/../pkgbuilds}" words="" file base i

  if ((COMP_CWORD == start + 1)); then
    mapfile -t COMPREPLY < <(compgen -W "build list rm clean" -- "$cur")
    return 0
  fi

  case "$prev" in
    --pkgbuilds | --src)
      compopt -o filenames 2>/dev/null
      mapfile -t COMPREPLY < <(compgen -d -- "$cur")
      return 0
      ;;
    --dir) return 0 ;;
  esac

  for ((i = start + 2; i < COMP_CWORD; i++)); do
    [[ "${COMP_WORDS[i]}" == --pkgbuilds ]] && pkgbuilds="${COMP_WORDS[i + 1]}"
  done

  case "${COMP_WORDS[start + 1]}" in
    build)
      words="--pkgbuilds --src --dir"
      for file in "$pkgbuilds"/*/PKGBUILD; do
        [[ -f "$file" ]] && file="${file%/PKGBUILD}" && words+=" ${file##*/}"
      done
      ;;
    rm)
      for file in "$root"/mkosi.packages/*.pkg.tar*; do
        [[ -f "$file" && "$file" != *.sig ]] || continue
        base="${file##*/}"
        base="${base%.pkg.tar*}"
        words+=" ${base%-*-*-*}"
      done
      ;;
  esac
  mapfile -t COMPREPLY < <(compgen -W "$words" -- "$cur")
}

_garuda_build() {
  local cur="${COMP_WORDS[COMP_CWORD]}" prev="${COMP_WORDS[COMP_CWORD - 1]}" root i output="" pos=0
  local outputs="distrobox lima iso vm uki clean"
  local options="--refresh-keys --fresh --rebuild-layer --explain --container --rebuild-builder --help"
  local layers="base root desktop live mhwd live-initrd"
  local levels="old layers caches all"

  root="$(git rev-parse --show-toplevel 2>/dev/null)" || return 0
  # Only the devshell wrapper has pkg, as its first argument, see scripts/build.sh
  if [[ "${COMP_WORDS[0]##*/}" == build && "${COMP_WORDS[1]}" == pkg ]] && ((COMP_CWORD > 1)); then
    _garuda_build_pkg 1 "$root"
    return 0
  fi
  [[ "${COMP_WORDS[0]##*/}" == build ]] && ((COMP_CWORD == 1)) && outputs+=" pkg"

  if [[ "$prev" == --rebuild-layer ]]; then
    mapfile -t COMPREPLY < <(compgen -W "$layers" -- "$cur")
    return 0
  fi

  # The output is the first word that is not an option or a layer of --rebuild-layer
  for ((i = 1; i < COMP_CWORD; i++)); do
    case "${COMP_WORDS[i]}" in
      --rebuild-layer) ((i++)) ;;
      --*) ;;
      *)
        output="${COMP_WORDS[i]}"
        pos=$((COMP_CWORD - i))
        break
        ;;
    esac
  done

  local words=""
  case "$output:$pos" in
    :*) words="$outputs $options" ;;
    iso:1 | vm:1) words="$(cd "$root/mkosi.images/desktop/mkosi.profiles" 2>/dev/null && printf '%s ' */ | tr -d /)" ;;
    clean:1) words="$levels" ;;
    clean:2) words="--yes" ;;
  esac
  mapfile -t COMPREPLY < <(compgen -W "$words" -- "$cur")
}

complete -F _garuda_build build build.sh ./build.sh
