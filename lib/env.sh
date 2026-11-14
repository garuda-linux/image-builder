# shellcheck shell=bash
# .env.local of the checkout, see .env.local.example. The environment wins.

load_env_local() {
  local file="$1/.env.local" line key value
  [[ -f "$file" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue

    if [[ ! "$line" =~ ^(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      echo "$file: not a KEY=value line: $line" >&2
      return 1
    fi

    key="${BASH_REMATCH[2]}"
    value="${BASH_REMATCH[3]}"
    if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then
      value="${BASH_REMATCH[1]}"
    fi

    [[ -n "${!key+set}" ]] && continue
    export "$key=$value"
  done <"$file"
}
