_garuda_build() {
  local cur="${COMP_WORDS[COMP_CWORD]}" prev="${COMP_WORDS[COMP_CWORD - 1]}" root i output="" pos=0
  local outputs="distrobox lima iso vm uki clean"
  local options="--refresh-keys --fresh --rebuild-layer --explain --container --rebuild-builder --help"
  local layers="base root desktop live mhwd live-initrd"
  local levels="old layers caches all"

  root="$(git rev-parse --show-toplevel 2>/dev/null)" || return 0

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
