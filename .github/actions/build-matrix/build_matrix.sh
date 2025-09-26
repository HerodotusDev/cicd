#!/usr/bin/env bash
set -euo pipefail

workspace="${GITHUB_WORKSPACE:-.}"
extract_script="$workspace/.github/actions/extract-version/extract_version.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "❌ Error: jq is required but not available." >&2
  exit 1
fi

app_matrix_raw="${APP_MATRIX:-}"
raw_app_names="${RAW_APP_NAMES:-}"
init_pods_raw="${INIT_PODS:-}"
default_version_file="${DEFAULT_VERSION_FILE:-./package.json}"
default_version_key="${DEFAULT_VERSION_KEY:-}"

tmp_apps=$(mktemp)
trap 'rm -f "$tmp_apps"' EXIT

if [[ -n "${app_matrix_raw}" && "${app_matrix_raw}" != "null" ]]; then
  apps_json="$app_matrix_raw"
elif [[ -n "${raw_app_names}" && "${raw_app_names}" != "null" ]]; then
  apps_json=$(printf '%s' "$raw_app_names" | jq -c 'map(if type=="object" then with_entries(select(.value != null)) else {name: (.|tostring)} end)')
else
  apps_json='[]'
fi

if [[ "${apps_json}" == '[]' ]]; then
  echo "❌ Error: At least one app must be defined in app_names." >&2
  exit 1
fi

sanitized=$(printf '%s' "$apps_json" | jq -c --arg default_file "$default_version_file" --arg default_key "$default_version_key" '
  map(
    .name = (.name // "" | tostring)
    | .version_file = (.version_file // $default_file)
    | (.version_key // $default_key) as $vk
    | .version_key = (if $vk == null or $vk == "" then null else $vk end)
    | .dockerfile = (.dockerfile // .name)
    | .context = (.context // .build_context // ".")
    | .etcd_name = (.etcd_app_name // .etcd_name // .name)
    | .manifest_name = (.manifest_name // .name)
    | with_entries(select(.value != null))
  )
')

primary_version=""
declare -a versions_seen=()

app_versions='{}'

while IFS= read -r app; do
  name=$(printf '%s' "$app" | jq -r '.name')
  if [[ -z "$name" || "$name" == "null" ]]; then
    echo "❌ Error: Each app entry must include a 'name' field." >&2
    exit 1
  fi

  version_file=$(printf '%s' "$app" | jq -r '.version_file')
  if [[ ! -f "$workspace/$version_file" && ! -f "$version_file" ]]; then
    echo "❌ Error: Version file '$version_file' not found for app '$name'." >&2
    exit 1
  fi
  if [[ -f "$workspace/$version_file" ]]; then
    version_path="$workspace/$version_file"
  else
    version_path="$version_file"
  fi

  version_key=$(printf '%s' "$app" | jq -r '.version_key // empty')

  if [[ -n "$version_key" ]]; then
    if ! version=$("$extract_script" --file "$version_path" --key "$version_key"); then
      echo "❌ Error: Failed to extract version for app '$name'." >&2
      exit 1
    fi
  else
    if ! version=$("$extract_script" --file "$version_path"); then
      echo "❌ Error: Failed to extract version for app '$name'." >&2
      exit 1
    fi
  fi

  if [[ -z "$version" ]]; then
    echo "❌ Error: Version not found for app '$name'." >&2
    exit 1
  fi

  printf '%s\n' "$app" | jq -c --arg version "$version" '(.version = $version) | (if (.version_key == null) then del(.version_key) else . end)' >> "$tmp_apps"
  app_versions=$(printf '%s' "$app_versions" | jq -c --arg name "$name" --arg version "$version" '. + {($name): $version}')

  versions_seen+=("$version")
  if [[ -z "$primary_version" ]]; then
    primary_version="$version"
  fi

done < <(printf '%s' "$sanitized" | jq -c '.[]')

matrix_apps=$(jq -cs '.' "$tmp_apps")

if [[ -z "$init_pods_raw" || "$init_pods_raw" == "null" || "$init_pods_raw" == "" ]]; then
  matrix_init='["__no_init__"]'
else
  if ! matrix_init=$(printf '%s' "$init_pods_raw" | jq -c 'if (type=="array") and (length>0) then . else ["__no_init__"] end'); then
    matrix_init='["__no_init__"]'
  fi
fi

if ((${#versions_seen[@]} > 0)); then
  unique_versions=$(printf '%s\n' "${versions_seen[@]}" | sort -u | jq -R -s 'split("\n") | map(select(length>0))' | jq -c '.')
else
  unique_versions='[]'
fi

if [[ $(printf '%s' "$unique_versions" | jq 'length') -eq 1 ]]; then
  should_tag="true"
else
  should_tag="false"
fi

{
  echo "matrix_apps=$matrix_apps"
  echo "matrix_init=$matrix_init"
  echo "app_versions=$app_versions"
  echo "unique_versions=$unique_versions"
  echo "primary_version=$primary_version"
  echo "should_tag=$should_tag"
} >> "${GITHUB_OUTPUT}"
