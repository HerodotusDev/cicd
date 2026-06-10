#!/usr/bin/env bash
# Parse a cicd-inputs.yaml into:
#   - one env var per top-level scalar key (arrays/objects emitted as compact JSON)
#   - app_names  : JSON array of app names
#   - app_matrix : JSON array of app objects (each with >=1 .name), null fields dropped
# Written to both $GITHUB_ENV and $GITHUB_OUTPUT. Uses yq (YAML->JSON) + jq.
set -euo pipefail

inputs_file="$1"
env_path="$2"
output_path="$3"

if [[ ! -f "$inputs_file" ]]; then
  echo "❌ Error: File $inputs_file not found!" >&2
  exit 1
fi
for tool in yq jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "❌ Error: $tool is required but not available." >&2; exit 1; }
done

# Convert the whole inputs file to compact JSON once; everything else is jq.
json=$(yq -o=json -I=0 '.' "$inputs_file")

# Normalize app_names into an array of objects (each with at least .name),
# dropping null fields. Accepts a block/flow list of strings or objects, or a
# single scalar (app_names: my-app).
app_matrix=$(printf '%s' "$json" | jq -c '
  (.app_names // [])
  | (if type=="array" then . else [.] end)
  | map(if type=="object" then with_entries(select(.value != null)) else {name: (.|tostring)} end)
')
app_names=$(printf '%s' "$app_matrix" | jq -c 'map(.name)')

# Every other top-level key -> env var (scalars raw; arrays/objects compact JSON).
while IFS= read -r key; do
  [[ "$key" == "app_names" ]] && continue
  vtype=$(printf '%s' "$json" | jq -r --arg k "$key" '.[$k] | type')
  if [[ "$vtype" == "array" || "$vtype" == "object" ]]; then
    val=$(printf '%s' "$json" | jq -c --arg k "$key" '.[$k]')
  else
    val=$(printf '%s' "$json" | jq -r --arg k "$key" '.[$k]')
  fi
  printf '%s=%s\n' "$key" "$val" >> "$env_path"
done < <(printf '%s' "$json" | jq -r 'keys_unsorted[]')

echo "app_names=$app_names"   >> "$env_path"
echo "app_matrix=$app_matrix" >> "$env_path"
echo "app_names=$app_names"   >> "$output_path"
echo "app_matrix=$app_matrix" >> "$output_path"
