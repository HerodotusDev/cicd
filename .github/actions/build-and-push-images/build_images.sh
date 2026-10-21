#!/usr/bin/env bash
# Parallel per-app builds against one buildx daemon.
#
# Every app shares the same Dockerfile DAG (APP_NAME only parameterizes the
# runtime stage), so concurrent builds deduplicate shared vertices: the
# workspace compile is computed once, then all runtime stages + pushes run
# concurrently. Concurrency is bounded by the repo-level `build_concurrency`
# cicd-inputs key (default 6).
#
# Cache scope resolution (highest wins): app.cache_scope → repo-level
# `cache_scope` (cicd-inputs top-level, exported as env by load-inputs) → app
# name. Arch is always appended so the two platform jobs never evict each
# other from the GHA cache bucket.
#
# Per-app behavior (tag-exists skip, repo overrides, etcd build-env pull,
# cache args, APP_NAME build-arg) mirrors the older per-app composite in
# ../build-and-push-image — that action remains for prewarm workflows that
# call it directly; keep the two in sync.
set -euo pipefail

: "${REGISTRY:?REGISTRY required}" "${MATRIX_DEPLOY:?MATRIX_DEPLOY required}" \
  "${APP_VERSIONS:?APP_VERSIONS required}" "${PLATFORMS:?PLATFORMS required}" \
  "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
IMAGE_SUFFIX="${IMAGE_SUFFIX:-}"
MATRIX_INIT="${MATRIX_INIT:-[]}"
PRIMARY_VERSION="${PRIMARY_VERSION:-}"
NAMESPACE="${NAMESPACE:-}"
ETCD_ROOT="${ETCD_ROOT:-}"
ETCD_USER="${ETCD_USER:-}"
ETCD_PASSWORD="${ETCD_PASSWORD:-}"
K8S_ENV="${K8S_ENV:-}"
BUILD_CONCURRENCY="${build_concurrency:-6}"
REPO_CACHE_SCOPE="${cache_scope:-}"
REPO="${GITHUB_REPOSITORY}"

case "${PLATFORMS}" in
  linux/amd64) arch="amd64" ;;
  linux/arm64) arch="arm64" ;;
  *) echo "❌ Error: unsupported platform '${PLATFORMS}' (expected linux/amd64 or linux/arm64)." >&2; exit 1 ;;
esac

for tool in jq yq docker; do
  command -v "$tool" >/dev/null 2>&1 || { echo "❌ Error: $tool is required but not available." >&2; exit 1; }
done

overrides_file="${GITHUB_ACTION_PATH}/../resolve-overrides/overrides.yaml"
default_etcd_host="http://etcd.etcd.svc.cluster.local:2379"
etcd_pull="${GITHUB_ACTION_PATH}/../etcd-pull/pull.sh"
env_dir="${RUNNER_TEMP:-/tmp}/build-env"
log_dir="${RUNNER_TEMP:-/tmp}/build-logs"
mkdir -p "${env_dir}" "${log_dir}"

# Apps to build: deploy apps + init apps that own their image (init apps
# reusing another app's image are covered by that app's build).
apps_json=$(jq -cn \
  --argjson deploy "${MATRIX_DEPLOY}" \
  --argjson init "${MATRIX_INIT}" '
  ($deploy | map(. + {_kind: "deploy"}))
  + ($init
     | map(select(.name != "__no_init__"))
     | map(select((.image // .name) == .name))
     | map(. + {_kind: "init"}))
  | unique_by(.name)')
count=$(jq 'length' <<<"${apps_json}")

# Phase A (serial): pull etcd build-env for apps that need it. Serial because
# pull.sh populates a shared etcdctl binary path on first use, and the volume
# is tiny — parallelizing this phase buys nothing.
while IFS= read -r app; do
  [[ -z "${app}" ]] && continue
  name=$(jq -r '.name' <<<"${app}")
  etcd_name=$(jq -r '.etcd_name // .name' <<<"${app}")

  ovr_host=$(yq ".etcd_hosts.\"${NAMESPACE}\".host // \"\"" "${overrides_file}")
  ovr_user=$(yq ".etcd_hosts.\"${NAMESPACE}\".user // \"\"" "${overrides_file}")
  ovr_password_env=$(yq ".etcd_hosts.\"${NAMESPACE}\".password_env // \"\"" "${overrides_file}")
  etcd_host="${ovr_host:-${default_etcd_host}}"
  etcd_user="${ovr_user:-${ETCD_USER}}"
  etcd_password="${ETCD_PASSWORD}"
  if [[ -n "${ovr_password_env}" ]]; then
    etcd_password="${!ovr_password_env:-}"
  fi

  echo "Fetching etcd build-env: /${ETCD_ROOT}/${K8S_ENV}/${etcd_name}/.env"
  ETCD_HOST="${etcd_host}" \
  ETCD_USER="${etcd_user}" \
  ETCD_PASSWORD="${etcd_password}" \
  ETCD_KEY="/${ETCD_ROOT}/${K8S_ENV}/${etcd_name}/.env" \
  APP_NAME="${etcd_name}" \
  NAMESPACE="${NAMESPACE}" \
  OUTPUT_FILE="${env_dir}/${name}.secret.yaml" \
  bash "${etcd_pull}" || true

  if [[ -s "${env_dir}/${name}.secret.yaml" ]]; then
    # Extract KEY=VALUE lines from the base64 secret data.
    out="${env_dir}/${name}.env"
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
    done < "${env_dir}/${name}.secret.yaml"
    rm -f "${env_dir}/${name}.secret.yaml"
    if [[ ! -s "${out}" ]]; then
      echo "::warning::Failed to extract env vars for ${name}"
    fi
  else
    echo "::warning::No .env found at etcd key /${ETCD_ROOT}/${K8S_ENV}/${etcd_name}/.env — ${name} builds without it"
  fi
done < <(jq -c '.[] | select((.etcd_build_env // false) == true)' <<<"${apps_json}")

# Phase B (parallel): one buildx build per app.
build_one() {
  set -euo pipefail
  local app="$1"
  local name kind version dockerfile_default context app_platforms cache_mode app_scope etcd_build_env
  name=$(jq -r '.name' <<<"${app}")
  kind=$(jq -r '._kind' <<<"${app}")
  if [[ "${kind}" == "init" ]]; then
    version="${PRIMARY_VERSION}"
  else
    version=$(jq -r --arg n "${name}" '.[$n]' <<<"${APP_VERSIONS}")
  fi
  if [[ -z "${version}" || "${version}" == "null" ]]; then
    echo "❌ ${name}: no resolved version." >&2
    return 1
  fi
  dockerfile_default=$(jq -r '.dockerfile // .name' <<<"${app}")
  context=$(jq -r '.context // "."' <<<"${app}")
  app_platforms=$(jq -r '.platforms // "linux/amd64,linux/arm64"' <<<"${app}")
  cache_mode=$(jq -r '.cache_mode // "max"' <<<"${app}")
  app_scope=$(jq -r '.cache_scope // ""' <<<"${app}")
  etcd_build_env=$(jq -r '(.etcd_build_env // false) | tostring' <<<"${app}")

  if [[ "${app_platforms}" != *"linux/${arch}"* ]]; then
    echo "⏭  ${name}: platforms '${app_platforms}' exclude linux/${arch}"
    return 0
  fi

  # Repo-level Dockerfile override + APP_NAME strip prefix (resolve-overrides).
  local dockerfile strip app_base app_arg
  dockerfile=$(yq ".repos.\"${REPO}\".dockerfile // \"\"" "${overrides_file}")
  if [[ -z "${dockerfile}" ]]; then
    dockerfile="${dockerfile_default}"
  fi
  strip=$(yq ".repos.\"${REPO}\".app_arg_strip_prefix // \"\"" "${overrides_file}")
  app_base="${name}"
  if [[ -n "${strip}" ]]; then
    app_base="${name#"${strip}"}"
  fi
  app_arg="app-${app_base}"

  local image="${REGISTRY}/${name}${IMAGE_SUFFIX}"
  local arch_tag="${image}:${version}-${arch}"

  if docker manifest inspect "${arch_tag}" >/dev/null 2>&1; then
    echo "⏭  ${name}: image ${arch_tag} exists"
    return 0
  fi

  # Apps with an injected build env build from an isolated context copy so
  # parallel workers never race on .env.production in the shared checkout.
  local ctx="${context}"
  if [[ "${etcd_build_env}" == "true" ]]; then
    ctx="${RUNNER_TEMP:-/tmp}/build-ctx-${name}"
    rm -rf "${ctx}"
    cp -a "${context}" "${ctx}"
    if [[ -s "${env_dir}/${name}.env" ]]; then
      cp "${env_dir}/${name}.env" "${ctx}/.env.production"
      echo "${name}: injected .env.production ($(wc -l < "${env_dir}/${name}.env") lines)"
    else
      echo "::warning::${name}: no build-env file — building without .env.production"
    fi
  fi

  local scope="${app_scope:-${REPO_CACHE_SCOPE:-${name}}}-${arch}"
  local log="${log_dir}/${name}.log"
  local t0 t1
  t0=$(date +%s)

  echo "Building ${arch_tag} (dockerfile docker/Dockerfile.${dockerfile}, APP_NAME=${app_arg})"
  if ! docker buildx build \
    --progress=plain \
    --push \
    --platform "${PLATFORMS}" \
    --file "${ctx}/docker/Dockerfile.${dockerfile}" \
    --cache-from "type=gha,scope=${scope}" \
    --cache-to "type=gha,mode=${cache_mode},scope=${scope}" \
    --network host \
    --tag "${arch_tag}" \
    --build-arg "APP_NAME=${app_arg}" \
    "${ctx}" >"${log}" 2>&1; then
    echo "❌ ${name}: build failed — last 40 log lines:"
    tail -40 "${log}"
    return 1
  fi

  t1=$(date +%s)
  echo "✅ ${name}: pushed ${arch_tag} ($((t1 - t0))s)"
}

export REGISTRY IMAGE_SUFFIX APP_VERSIONS PRIMARY_VERSION PLATFORMS NAMESPACE K8S_ENV \
  REPO REPO_CACHE_SCOPE overrides_file env_dir log_dir arch

echo "Parallel build: ${count} app(s), platform ${PLATFORMS}, concurrency ${BUILD_CONCURRENCY}."

declare -a pids=() names=() app_lines=()
mapfile -t app_lines < <(jq -c '.[]' <<<"${apps_json}")
for app in "${app_lines[@]}"; do
  names+=("$(jq -r '.name' <<<"${app}")")
  ( build_one "${app}" ) &
  pids+=($!)
  while (( $(jobs -rp | wc -l) >= BUILD_CONCURRENCY )); do
    sleep 2
  done
done

failed=0
for i in "${!pids[@]}"; do
  if ! wait "${pids[$i]}"; then
    failed=1
    echo "::error::Build failed for ${names[$i]}"
  fi
done

if (( failed != 0 )); then
  exit 1
fi
echo "Parallel build complete: ${count} app(s) processed (${PLATFORMS})."
