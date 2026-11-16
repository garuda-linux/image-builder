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

_garuda_build_editions() {
  (cd "$1/mkosi.images/desktop/mkosi.profiles" 2>/dev/null && printf '%s ' */ | tr -d /)
}

# _garuda_build_verb <verb> <start> <root>
_garuda_build_verb() {
  local verb="$1" start="$2" root="$3" cur="${COMP_WORDS[COMP_CWORD]}" words=""
  local output="${COMP_WORDS[start + 1]}" pos=$((COMP_CWORD - start)) file

  case "$verb:$output:$pos" in
    test:*:1) words="iso vm lima distrobox oci" ;;
    virt:*:1) words="iso vm list rm" ;;
    virt:rm:*) words="--all $(virsh --connect qemu:///system --quiet list --all --name 2>/dev/null | grep '^garuda-')" ;;
    test:iso:*) words="--openqa --cdrom --disk --boot-disk --secure-boot --keep --serial --ram= --version=" ;;
    test:vm:*) words="--keep --serial --ssh --ram= --version=" ;;
    test:lima:*) words="--keep" ;;
    virt:iso:*) words="--new --new= --open --attach --disk --secure-boot --ram= --version=" ;;
    virt:vm:*) words="--new --new= --open --attach --ram= --version=" ;;
    journal:*:1) words="iso vm virt" ;;
    journal:virt:2) words="$(cd "${XDG_STATE_HOME:-$HOME/.local/state}/garuda-libvirt" 2>/dev/null && printf '%s ' */ | tr -d /)" ;;
    shell:*:1) words="base root desktop" ;;
    shell:*:2) words="--" ;;
    diff:*:1 | flash:*:1 | verify:*:1) words="$(_garuda_build_editions "$root")" ;;
    diff:*:2 | diff:*:3)
      for file in "$root/mkosi.output/garuda-$output"-linux*-20[0-9]*.iso.manifest; do
        [[ -f "$file" ]] || continue

        file="${file%.iso.manifest}"
        words+=" ${file##*-}"
      done
      ;;
    flash:*:*) words="--yes --version= $(lsblk -dnpo NAME,TYPE 2>/dev/null | awk '$2 == "disk" && $1 !~ /zram/ {print $1}')" ;;
    verify:*:*) words="--version=" ;;
  esac

  if [[ ("$verb" == test || "$verb" == virt) && ("$output" == iso || "$output" == vm) ]] && ((pos == 2)); then
    words+=" $(_garuda_build_editions "$root")"
  fi

  [[ "$words" == *= ]] && compopt -o nospace 2>/dev/null
  mapfile -t COMPREPLY < <(compgen -W "$words" -- "$cur")
}

# _garuda_build_items <items>: the next item of --test=a,b or --virt=a,b
_garuda_build_items() {
  local line="${COMP_LINE:0:COMP_POINT}" token rest done="" item
  token="${line##* }"
  rest="${token#*=}"

  # = breaks words in bash, so the value of an item such as ram=8 is a word of its own
  [[ "$rest" == *=* ]] && return 0
  [[ "$rest" == *,* ]] && done="${rest%,*},"

  COMPREPLY=()
  for item in $1; do
    [[ "$done$item" == "$rest"* ]] && COMPREPLY+=("$done$item")
  done

  compopt -o nospace 2>/dev/null
}

_garuda_build() {
  local cur="${COMP_WORDS[COMP_CWORD]}" prev="${COMP_WORDS[COMP_CWORD - 1]}" root i output="" pos=0
  local outputs="distrobox oci lima iso vm uki clean"
  local options="--refresh-keys --fresh --rebuild-layer --explain --container --rebuild-builder --help"
  local layers="base root desktop live drivers live-initrd"
  local levels="old layers caches all"

  root="$(git rev-parse --show-toplevel 2>/dev/null)" || return 0
  # The verbs, --notify, --test, --openqa, --tag and --virt exist only in the
  # devshell wrapper, see scripts/build.sh
  if [[ "${COMP_WORDS[0]##*/}" == build ]]; then
    local start=1 verb
    [[ "${COMP_WORDS[1]}" == --notify ]] && start=2
    verb="${COMP_WORDS[start]}"

    if [[ "$verb" == pkg ]] && ((COMP_CWORD > start)); then
      _garuda_build_pkg "$start" "$root"
      return 0
    fi

    case "$verb" in
      test | virt | ls | journal | shell | which | diff | flash | verify)
        if ((COMP_CWORD > start)); then
          _garuda_build_verb "$verb" "$start" "$root"
          return 0
        fi
        ;;
    esac

    ((COMP_CWORD == start)) && outputs+=" pkg test virt ls journal shell which diff flash verify"
    options+=" --notify --test --test= --openqa --tag --tag= --virt --virt="

    local token="${COMP_LINE:0:COMP_POINT}"
    case "${token##* }" in
      --test=*)
        _garuda_build_items "cdrom disk boot-disk secure-boot keep serial ssh ram= version="
        return 0
        ;;
      --virt=*)
        _garuda_build_items "new new= open attach disk secure-boot ram= version="
        return 0
        ;;
    esac
  fi

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
    iso:1 | vm:1) words="$(_garuda_build_editions "$root")" ;;
    clean:1) words="$levels" ;;
    clean:2) words="--yes" ;;
  esac
  mapfile -t COMPREPLY < <(compgen -W "$words" -- "$cur")
}

complete -F _garuda_build build build.sh ./build.sh
