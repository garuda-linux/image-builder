# shellcheck shell=bash
# Shared argument checks of the build and test scripts. Needs lib/log.sh.

check_edition() {
  [[ -n "$2" ]] || die "no edition given and EDITION is not set, for example: mokka"
  [[ -d "$1/mkosi.images/desktop/mkosi.profiles/$2" ]] || die "unknown edition $2, see scripts/editions.sh"
}

# ram_mib <size>: MiB from N, NM, NMiB, NG or NGiB
ram_mib() {
  [[ "$1" =~ ^([0-9]+)(M|MiB|G|GiB)?$ ]] || die "RAM size $1 is not N, NM, NMiB, NG or NGiB"
  case "${BASH_REMATCH[2]}" in
    G | GiB) echo $((BASH_REMATCH[1] * 1024)) ;;
    *) echo "${BASH_REMATCH[1]}" ;;
  esac
}

# check_state_dir <dir>: the test state dir must exist and be writable
check_state_dir() {
  if ! mkdir -p "$1" 2>/dev/null || [[ ! -w "$1" ]]; then
    die "$1 is not writable. A build creates it, or: sudo install -d -o $USER $1"
  fi
}
