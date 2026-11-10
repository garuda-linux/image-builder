# shellcheck shell=bash

TIMINGS_FILE="$OUTPUT_DIR/.timings"

# timing_add <label> <seconds>
timing_add() {
  printf '%s\t%s\n' "$1" "$2" >>"$TIMINGS_FILE"
}

# timed <label> <command...>: runs the command and records its time.
timed() {
  local label="$1" start=$SECONDS
  shift
  "$@"
  timing_add "$label" "$((SECONDS - start))"
}

# Filter for mkosi's output: passes every line on and records the time per
# image, from the "‣ [<image>] ..." prefix of mkosi's log lines
mkosi_image_timings() {
  local line image current="" start=$SECONDS

  while IFS= read -r line; do
    printf '%s\n' "$line"
    [[ "$line" =~ ^‣\ +\[([A-Za-z0-9_.-]+)\] ]] || continue

    image="${BASH_REMATCH[1]}"
    if [[ "$image" != "$current" ]]; then
      [[ -n "$current" ]] && timing_add "mkosi $current" "$((SECONDS - start))"
      current="$image" start=$SECONDS
    fi
  done

  [[ -n "$current" ]] && timing_add "mkosi $current" "$((SECONDS - start))"
  return 0
}

timings_start() {
  mkdir -p "$OUTPUT_DIR"
  : >"$TIMINGS_FILE"
  trap timings_print EXIT
}

timings_print() {
  local label seconds

  [[ -s "$TIMINGS_FILE" ]] || return 0
  printf '\033[1;32m==>\033[0m Timings\n'

  while IFS=$'\t' read -r label seconds; do
    printf '    %-32s %3d:%02d\n' "$label" "$((seconds / 60))" "$((seconds % 60))"
  done <"$TIMINGS_FILE"
}
