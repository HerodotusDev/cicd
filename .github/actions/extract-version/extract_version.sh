#!/usr/bin/env bash
set -euo pipefail

trim() {
  local val="$1"
  val="${val#${val%%[![:space:]]*}}"
  val="${val%${val##*[![:space:]]}}"
  printf '%s' "$val"
}

strip_quotes() {
  local val="$1"
  if [[ ${#val} -ge 2 ]]; then
    local first=${val:0:1}
    local last=${val: -1}
    if [[ "$first" == '"' && "$last" == '"' ]] || [[ "$first" == "'" && "$last" == "'" ]]; then
      val=${val:1:-1}
    fi
  fi
  printf '%s' "$val"
}

print_error() {
  echo "❌ Error: $*" >&2
  exit 1
}

file=""
key=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)
      file="$2"
      shift 2
      ;;
    --key)
      key="$2"
      shift 2
      ;;
    *)
      print_error "Unknown argument $1"
      ;;
  esac
done

[[ -z "$file" ]] && print_error "--file is required"
[[ ! -f "$file" ]] && print_error "File not found: $file"

if [[ ! -s "$file" ]]; then
  print_error "File is empty: $file"
fi

ext="${file##*.}"

if [[ "${ext,,}" == "json" ]]; then
  if ! command -v jq >/dev/null 2>&1; then
    print_error "jq is required but not available"
  fi
  if [[ -n "$key" ]]; then
    path_json=$(jq -cn --arg key "$key" '$key | split(".")')
    value=$(jq -er --argjson path "$path_json" 'getpath($path)' "$file" 2>/dev/null || true)
  else
    value=$(jq -er '.version' "$file" 2>/dev/null || true)
  fi
  if [[ -z "${value:-}" || "$value" == "null" ]]; then
    print_error "Version not found in $file"
  fi
  printf '%s\n' "$value"
  exit 0
fi

if [[ "${ext,,}" != "toml" ]]; then
  print_error "Unsupported file type: $file"
fi

parse_toml_version() {
  local toml_file="$1"
  local key_path="$2"

  local find_first=0
  local target_key="version"
  local target_section=""

  if [[ -n "$key_path" ]]; then
    IFS='.' read -r -a parts <<< "$key_path"
    target_key="${parts[-1]}"
    if (( ${#parts[@]} > 1 )); then
      target_section=$(IFS='.'; printf '%s' "${parts[*]:0:${#parts[@]}-1}")
    fi
  else
    find_first=1
  fi

  local current_section=""

  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    local line="${raw_line%%#*}"
    line=$(trim "$line")
    [[ -z "$line" ]] && continue

    if [[ "$line" =~ ^\[\[(.*)\]\]$ ]]; then
      local section="${BASH_REMATCH[1]}"
      section=$(strip_quotes "$(trim "$section")")
      current_section="$section"
      continue
    elif [[ "$line" =~ ^\[(.*)\]$ ]]; then
      local section="${BASH_REMATCH[1]}"
      section=$(strip_quotes "$(trim "$section")")
      current_section="$section"
      continue
    fi

    if [[ "$line" != *=* ]]; then
      continue
    fi

    local before_eq="${line%%=*}"
    local after_eq="${line#*=}"
    local key_candidate=$(strip_quotes "$(trim "$before_eq")")
    local value_candidate="${after_eq%%#*}"
    value_candidate=$(trim "$value_candidate")
    value_candidate="${value_candidate%,}"
    value_candidate=$(strip_quotes "$value_candidate")

    if (( find_first )); then
      if [[ "$key_candidate" == "$target_key" ]]; then
        printf '%s\n' "$value_candidate"
        return 0
      fi
      continue
    fi

    if [[ "$key_candidate" != "$target_key" ]]; then
      continue
    fi

    if [[ -z "$target_section" ]]; then
      if [[ -z "$current_section" ]]; then
        printf '%s\n' "$value_candidate"
        return 0
      else
        continue
      fi
    fi

    if [[ "$current_section" == "$target_section" ]]; then
      printf '%s\n' "$value_candidate"
      return 0
    fi
  done < "$toml_file"

  return 1
}

if version=$(parse_toml_version "$file" "$key" ); then
  printf '%s\n' "$version"
else
  print_error "Version not found in $file"
fi
