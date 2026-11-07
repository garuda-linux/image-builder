# shellcheck shell=sh
# Kernel command line helpers, sourced by garuda-live-generator and garuda-live-mount

read -r cmdline </proc/cmdline

# arg <name>: the value of <name>=<value>. The last one wins, as with systemd.
arg() {
  v=""
  # shellcheck disable=SC2086 # split the command line into its arguments
  for a in $cmdline; do
    case "$a" in
      "$1"=*) v="${a#*=}" ;;
    esac
  done
  echo "$v"
}

# flag <name>: true for <name> and <name>=y
flag() {
  # shellcheck disable=SC2086 # split the command line into its arguments
  for a in $cmdline; do
    [ "$a" = "$1" ] || [ "$a" = "$1=y" ] && return 0
  done
  return 1
}
