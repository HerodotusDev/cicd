#!/usr/bin/env bash
# Sequential build loop for build-and-deploy (build-strategy: sequential).
#
# Runs every app from matrix_deploy in ONE buildx context on one runner: the
# first build compiles the shared layers (e.g. a workspace-wide Rust build) and
# every subsequent build reuses them from the in-job builder cache instead of
# recompiling per matrix job. Fails fast on the first build failure.
#
# Per-app behavior replicates the parallel path; keep these in sync:
#   - .github/actions/build-and-push-image/action.yaml (checkout, login, IMAGE,
#     tag-exists skip, overrides, .env injection, build-push args)
#   - .github/actions/resolve-overrides/action.yaml    (dockerfile/app_arg/etcd lookups)
#   - .github/actions/pull-etcd-build-env/action.yaml  (etcd build-env pull)
set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "❌ Error: jq is required but not available." >&2
  exit 1
fi
if ! command -v yq >/dev/null 2>&1; then
  echo "❌ Error: yq is required but not available (load-inputs normally bootstraps it)." >&2
  exit 1
fi

overrides_file="${GITHUB_ACTION_PATH}/../resolve-overrides/overrides.yaml"
repo="${GITHUB_REPOSITORY}"
default_etcd_host="http://etcd.etcd.svc.cluster.local:2379"

apps_length=$(printf '%s' "${MATRIX_DEPLOY:-[]}" | jq 'length')
if [[ "${apps_length}" -eq 0 ]]; then
  echo "No deploy apps requested. Nothing to build."
  exit 0
fi
echo "Sequential build: ${apps_length} app(s) in one buildx context."

for ((i = 0; i < apps_length; i++)); do
  app=$(printf '%s' "${MATRIX_DEPLOY}" | jq -c ".[${i}]")
  name=$(printf '%s' "${app}" | jq -r '.name')
  version=$(printf '%s' "${APP_VERSIONS}" | jq -r --arg n "${name}" '.[$n]')
  if [[ -z "${version}" || "${version}" == "null" ]]; then
    echo "❌ Error: No resolved version for app '${name}'." >&2
    exit 1
  fi
  dockerfile_default=$(printf '%s' "${app}" | jq -r '.dockerfile // .name')
  context=$(printf '%s' "${app}" | jq -r '.context // "."')
  cache_mode=$(printf '%s' "${app}" | jq -r '.cache_mode // "max"')
  cache_scope=$(printf '%s' "${app}" | jq -r '.cache_scope // ""')
  etcd_build_env=$(printf '%s' "${app}" | jq -r '(.etcd_build_env // false) | tostring')
  etcd_name=$(printf '%s' "${app}" | jq -r '.etcd_name // .name')

  echo "::group::[$((i + 1))/${apps_length}] ${name} (version ${version})"

  image="${DOCKERHUB_PROJECT}/${IMAGE_PREFIX}${name}"

  # resolve-overrides: repo dockerfile override + APP_NAME strip prefix.
  dockerfile=$(yq ".repos.\"${repo}\".dockerfile // \"\"" "${overrides_file}")
  [[ -z "${dockerfile}" ]] && dockerfile="${dockerfile_default}"
  strip=$(yq ".repos.\"${repo}\".app_arg_strip_prefix // \"\"" "${overrides_file}")
  app_base="${name}"
  [[ -n "${strip}" ]] && app_base="${name#"${strip}"}"
  app_arg="app-${app_base}"

  # Skip when the version tag already exists on the registry.
  if docker manifest inspect "${image}:${version}" >/dev/null 2>&1; then
    echo "Docker image '${image}:${version}' exists. Skipping."
    echo "::endgroup::"
    continue
  fi

  env_file=""
  if [[ "${etcd_build_env}" == "true" ]]; then
    # resolve-overrides etcd host/user/password lookups + pull-etcd-build-env.
    ovr_host=$(yq ".etcd_hosts.\"${NAMESPACE}\".host // \"\"" "${overrides_file}")
    ovr_net=$(yq ".etcd_hosts.\"${NAMESPACE}\".docker_network // \"\"" "${overrides_file}")
    ovr_user=$(yq ".etcd_hosts.\"${NAMESPACE}\".user // \"\"" "${overrides_file}")
    ovr_password_env=$(yq ".etcd_hosts.\"${NAMESPACE}\".password_env // \"\"" "${overrides_file}")
    if [[ -n "${ovr_host}" ]]; then
      etcd_host="${ovr_host}"
      etcd_net="${ovr_net:-host}"
    else
      etcd_host="${default_etcd_host}"
      etcd_net="bridge"
    fi
    etcd_user="${ovr_user:-${ETCD_USER}}"
    if [[ -n "${ovr_password_env}" ]]; then
      etcd_password="${!ovr_password_env:-}"
    else
      etcd_password="${ETCD_PASSWORD}"
    fi

    etcd_key="/${ETCD_ROOT}/${K8S_ENV}/${etcd_name}/.env"
    output_dir="${GITHUB_WORKSPACE}/build-env-output"
    mkdir -p "${output_dir}"
    echo "Fetching etcd key: ${etcd_key}"
    network_flag=""
    [[ "${etcd_net}" == "host" ]] && network_flag="--network host"
    docker run --rm ${network_flag} \
      -e ETCD_HOST="${etcd_host}" \
      -e ETCD_USER="${etcd_user}" \
      -e ETCD_PASSWORD="${etcd_password}" \
      -e ETCD_KEY="${etcd_key}" \
      -e APP_NAME="${etcd_name}" \
      -e NAMESPACE="${NAMESPACE}" \
      -v "${output_dir}:/output" \
      dataprocessor/etcd-pull:0.2 || true

    if [[ -s "${output_dir}/secret.yaml" ]]; then
      sudo chown -R "$(whoami):$(whoami)" "${output_dir}"
      # Truncate: the loop reuses the fixed path for every app.
      out="/tmp/etcd-build-env"
      : > "${out}"
      in_data=false
      while IFS= read -r line; do
        if [[ "${line}" == "data:" ]]; then
          in_data=true
          continue
        fi
        if ${in_data}; then
          if [[ "${line}" =~ ^[[:space:]]+([^:]+):[[:space:]]+(.+)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            decoded=$(echo "${val}" | base64 -d 2>/dev/null || echo "${val}")
            echo "${key}=${decoded}" >> "${out}"
          elif [[ ! "${line}" =~ ^[[:space:]] ]]; then
            break
          fi
        fi
      done < "${output_dir}/secret.yaml"
      if [[ -s "${out}" ]]; then
        env_file="${out}"
        echo "Wrote $(wc -l < "${out}") lines to ${out}"
      else
        echo "::warning::Failed to extract env vars from secret.yaml"
      fi
      rm -rf "${output_dir}"
    else
      echo "::warning::No .env found at etcd key ${etcd_key}"
    fi
  fi

  # build-and-push-image: inject build-time .env into the build context.
  if [[ -n "${env_file}" ]]; then
    if [[ -f "${env_file}" ]]; then
      cp "${env_file}" "${context}/.env.production"
      echo "Injected .env.production ($(wc -l < "${context}/.env.production") lines) into build context"
    else
      echo "::warning::build_env_file set but file not found at ${env_file}"
    fi
  fi

  cache_from="type=gha"
  cache_to="type=gha,mode=${cache_mode}"
  if [[ -n "${cache_scope}" ]]; then
    cache_from="type=gha,scope=${cache_scope}"
    cache_to="type=gha,mode=${cache_mode},scope=${cache_scope}"
  fi

  echo "Building ${image}:${version} (dockerfile ./docker/Dockerfile.${dockerfile}, APP_NAME=${app_arg})"
  docker buildx build \
    --push \
    --file "./docker/Dockerfile.${dockerfile}" \
    --cache-from "${cache_from}" \
    --cache-to "${cache_to}" \
    --network host \
    --tag "${image}:latest" \
    --tag "${image}:${version}" \
    --build-arg "APP_NAME=${app_arg}" \
    "${context}"

  echo "::endgroup::"
done

echo "Sequential build complete: ${apps_length} app(s) processed."
