#!/usr/bin/env bash
set -euo pipefail

inputs_file="$1"
env_path="$2"
output_path="$3"

if [[ ! -f "$inputs_file" ]]; then
  echo "❌ Error: File $inputs_file not found!" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "❌ Error: jq is required but not available." >&2
  exit 1
fi

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

normalize_value() {
  local raw="$1"
  local trimmed=$(trim "$raw")
  if [[ -z "$trimmed" ]]; then
    printf ''
    return
  fi
  if [[ "$trimmed" == \[* || "$trimmed" == \{* ]]; then
    printf '%s' "$trimmed" | jq -c '.'
  else
    local no_quotes=$(strip_quotes "$trimmed")
    printf '%s' "$no_quotes"
  fi
}

INDENT_RESULT=0
CONTENT_RESULT=""
get_indent_and_content() {
  local line="$1"
  line="${line%%#*}"
  line="${line%$'\r'}"
  while [[ "$line" =~ [[:space:]]$ ]]; do line="${line%?}"; done
  if [[ -z "$line" ]]; then
    INDENT_RESULT=-1
    CONTENT_RESULT=""
    return
  fi
  local leading="${line%%[![:space:]]*}"
  INDENT_RESULT=${#leading}
  CONTENT_RESULT="${line#$leading}"
}

add_to_object() {
  local var_name="$1"
  local key="$2"
  local value="$3"
  local -n obj_ref="$var_name"
  if [[ -z "$key" ]]; then
    return
  fi
  if [[ "$value" == \[* || "$value" == \{* ]]; then
    obj_ref=$(printf '%s' "$obj_ref" | jq --arg key "$key" --argjson val "$value" '. + {($key): $val}')
  else
    local lower=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')
    if [[ "$lower" == "true" || "$lower" == "false" || "$lower" == "null" ]]; then
      obj_ref=$(printf '%s' "$obj_ref" | jq --arg key "$key" --argjson val "$lower" '. + {($key): $val}')
    else
      obj_ref=$(printf '%s' "$obj_ref" | jq --arg key "$key" --arg val "$value" '. + {($key): $val}')
    fi
  fi
}

SIMPLE_LIST_RESULT='[]'
parse_scalar_list_block() {
  local start_idx="$1"
  local base_indent="$2"
  local total="$3"
  local -n lines_ref="$4"

  local idx=$((start_idx + 1))
  local arr_json='[]'

  while (( idx < total )); do
    get_indent_and_content "${lines_ref[idx]}"
    if (( INDENT_RESULT == -1 )); then
      ((idx+=1))
      continue
    fi
    local indent=$INDENT_RESULT
    local content=$CONTENT_RESULT
    if (( indent <= base_indent )); then
      break
    fi
    if (( indent == base_indent + 2 )) && [[ "$content" == -* ]]; then
      local value=$(normalize_value "${content#- }")
      value=$(strip_quotes "$value")
      arr_json=$(printf '%s' "$arr_json" | jq --arg v "$value" '. + [$v]')
    fi
    ((idx+=1))
  done
  SIMPLE_LIST_RESULT=$(printf '%s' "$arr_json" | jq -c '.')
  NEXT_INDEX=$idx
}

NEXT_INDEX=0
parse_app_names_block() {
  local start_idx="$1"
  local base_indent="$2"
  local total="$3"
  local -n lines_ref="$4"
  local -n matrix_ref="$5"
  local -n names_ref="$6"

  local idx=$((start_idx + 1))
  local entries=()
  local current_json='{}'
  local have_current=0

  while (( idx < total )); do
    get_indent_and_content "${lines_ref[idx]}"
    if (( INDENT_RESULT == -1 )); then
      ((idx+=1))
      continue
    fi
    local indent=$INDENT_RESULT
    local content=$CONTENT_RESULT
    if (( indent <= base_indent )); then
      break
    fi
    if (( indent == base_indent + 2 )); then
      if [[ "$content" != -* ]]; then
        break
      fi
      if (( have_current )); then
        entries+=("$current_json")
      fi
      have_current=1
      current_json='{}'
      content="${content#- }"
      if [[ -z "$content" ]]; then
        ((idx+=1))
        continue
      fi
      if [[ "$content" == *:* ]]; then
        local key=$(trim "${content%%:*}")
        local rest=$(normalize_value "${content#*:}")
        add_to_object current_json "$key" "$rest"
      else
        local name=$(strip_quotes "$(trim "$content")")
        add_to_object current_json "name" "$name"
      fi
      ((idx+=1))
      continue
    else
      if (( ! have_current )); then
        echo "❌ Error: invalid structure in app_names block." >&2
        exit 1
      fi
      if [[ "$content" == -* ]]; then
        echo "❌ Error: nested lists in app_names block are not supported." >&2
        exit 1
      fi
      if [[ "$content" != *:* ]]; then
        ((idx+=1))
        continue
      fi
      local key=$(trim "${content%%:*}")
      local rest=$(normalize_value "${content#*:}")
      add_to_object current_json "$key" "$rest"
      ((idx+=1))
    fi
  done

  if (( have_current )); then
    entries+=("$current_json")
  fi

  if ((${#entries[@]} == 0)); then
    matrix_ref='[]'
    names_ref='[]'
  else
    matrix_ref=$(printf '%s\n' "${entries[@]}" | jq -cs '.')
    names_ref=$(printf '%s' "$matrix_ref" | jq -c 'map(.name)')
  fi
  NEXT_INDEX=$idx
}

mapfile -t lines < "$inputs_file"

declare -A env_map=()
app_matrix_json=''
app_names_json=''

total_lines=${#lines[@]}
idx=0
while (( idx < total_lines )); do
  get_indent_and_content "${lines[idx]}"
  if (( INDENT_RESULT == -1 )); then
    ((idx+=1))
    continue
  fi
  indent=$INDENT_RESULT
  content=$CONTENT_RESULT
  if (( indent != 0 )) || [[ "$content" != *:* ]]; then
    ((idx+=1))
    continue
  fi
  key=$(trim "${content%%:*}")
  rest=$(trim "${content#*:}")

  if [[ "$key" == "app_names" ]]; then
    if [[ -n "$rest" ]]; then
      minified=$(printf '%s' "$rest" | jq -c '.')
      app_matrix_json=$(printf '%s' "$minified" | jq -c 'map(if type=="object" then with_entries(select(.value != null)) else {name: (tostring)} end)')
      app_names_json=$(printf '%s' "$app_matrix_json" | jq -c 'map(.name)')
      env_map["app_names"]="$app_names_json"
    else
      parse_app_names_block "$idx" "$indent" "$total_lines" lines app_matrix_json app_names_json
      env_map["app_names"]="$app_names_json"
      idx=$((NEXT_INDEX - 1))
    fi
  else
    env_value=""
    if [[ -n "$rest" ]]; then
      if [[ "$rest" == \[* || "$rest" == \{* ]]; then
        env_value=$(printf '%s' "$rest" | jq -c '.')
      else
        env_value=$(normalize_value "$rest")
      fi
    else
      parse_scalar_list_block "$idx" "$indent" "$total_lines" lines
      env_value="$SIMPLE_LIST_RESULT"
      idx=$((NEXT_INDEX - 1))
    fi
    env_map["$key"]="$env_value"
  fi

  ((idx+=1))
done

if [[ -z "$app_matrix_json" ]]; then
  if [[ -n "${env_map[app_names]:-}" ]]; then
    app_names_json="${env_map[app_names]}"
    app_matrix_json=$(printf '%s' "$app_names_json" | jq -c 'map({name: (tostring)})')
  else
    app_names_json='[]'
    app_matrix_json='[]'
    env_map[app_names]='[]'
  fi
elif [[ -z "$app_names_json" ]]; then
  app_names_json=$(printf '%s' "$app_matrix_json" | jq -c 'map(.name)')
  env_map[app_names]="$app_names_json"
fi

# Write environment variables (skip app_names here to avoid duplicates)
keys=()
for key in "${!env_map[@]}"; do
  keys+=("$key")

done
IFS=$'\n' sorted_keys=($(printf '%s\n' "${keys[@]}" | sort))
unset IFS
for key in "${sorted_keys[@]}"; do
  if [[ "$key" == "app_names" ]]; then
    continue
  fi
  printf '%s=%s\n' "$key" "${env_map[$key]}" >> "$env_path"

done

echo "app_names=$app_names_json" >> "$env_path"
echo "app_matrix=$app_matrix_json" >> "$env_path"

echo "app_names=$app_names_json" >> "$output_path"
echo "app_matrix=$app_matrix_json" >> "$output_path"
