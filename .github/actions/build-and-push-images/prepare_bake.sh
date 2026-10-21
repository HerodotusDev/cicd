#!/usr/bin/env bash
# Prepare the bake file for the build job's docker/bake-action step.
#
# Every app shares the same Dockerfile DAG (APP_NAME only parameterizes the
# runtime stage), so a single `docker buildx bake` invocation lets BuildKit
# dedup the shared compile vertices: the workspace compile is computed once,
# the thin per-app runtime stages fan out concurrently. Parallelism is
# buildkit-internal — there is no job-level concurrency knob.
#
# Cache: per-arch buildx gha scope, resolution (highest wins) app.cache_scope
# → repo-level `cache_scope` (cicd-inputs top-level, exported as env by
# load-inputs) → app name. Version bumps do not change recipe.json (proven:
# cargo-chef normalizes workspace versions), so the dependency layers survive
# bumps once the cache entry exists.
#
# Apps with an injected build env (etcd_build_env) build from an isolated
# context copy (per-target context in the bake file) so targets never race on
# .env.production in the shared checkout.
#
# Per-app behavior (tag-exists skip, repo overrides, cache args, APP_NAME
# build-arg) mirrors the older per-app composite in ../build-and-push-image —
# that action remains for prewarm workflows that call it directly; keep the
# two in sync.
set -euo pipefail

: "${REGISTRY:?REGISTRY required}" "${MATRIX_DEPLOY:?MATRIX_DEPLOY required}" \
  "${APP_VERSIONS:?APP_VERSIONS required}" "${PLATFORMS:?PLATFORMS required}" \
  "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
IMAGE_SUFFIX="${IMAGE_SUFFIX:-}"
MATRIX_INIT="${MATRIX_INIT:-[]}"
PRIMARY_VERSION="${PRIMARY_VERSION:-}"
BUILD_ENV_PAYLOAD="${BUILD_ENV_PAYLOAD:-}"
K8S_ENV="${K8S_ENV:-}"
REPO_CACHE_SCOPE="${cache_scope:-}"
REPO="${GITHUB_REPOSITORY}"

if [[ -z "${BUILD_ENV_PAYLOAD}" ]]; then
  BUILD_ENV_PAYLOAD='{}'
fi

case "${PLATFORMS}" in
  linux/amd64) arch="amd64" ;;
  linux/arm64) arch="arm64" ;;
  *) echo "❌ Error: unsupported platform '${PLATFORMS}' (expected linux/amd64 or linux/arm64)." >&2; exit 1 ;;
esac

for tool in jq yq docker; do
  command -v "$tool" >/dev/null 2>&1 || { echo "❌ Error: $tool is required but not available." >&2; exit 1; }
done

overrides_file="${GITHUB_ACTION_PATH}/../resolve-overrides/overrides.yaml"
env_dir="${RUNNER_TEMP:-/tmp}/build-env"
# The bake definition and per-target contexts are resolved by buildkitd
# daemon-side inside the transferred local context: keep everything
# workspace-relative — absolute host paths don't exist inside the session.
bake_file="bake-${arch}.json"
ctx_root="${GITHUB_WORKSPACE}/.buildctx"
mkdir -p "${env_dir}" "${ctx_root}"

# Build-time env: decode the prep-provided payload into per-app .env files.
# The etcd pull already happened in prep, over its own tunnel — build jobs
# never open the repo's WG peer (one peer = one tunnel).
jq -r 'to_entries[] | "\(.key)\t\(.value)"' <<<"${BUILD_ENV_PAYLOAD}" |
while IFS=$'\t' read -r name b64; do
  if [[ -n "${b64}" ]]; then
    base64 -d <<<"${b64}" > "${env_dir}/${name}.env"
    echo "${name}: decoded build-time env ($(wc -l < "${env_dir}/${name}.env") lines)"
  fi
done

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

targets_json='{}'
targets=0
while IFS= read -r app; do
  [[ -z "${app}" ]] && continue
  name=$(jq -r '.name' <<<"${app}")
  kind=$(jq -r '._kind' <<<"${app}")
  if [[ "${kind}" == "init" ]]; then
    version="${PRIMARY_VERSION}"
  else
    version=$(jq -r --arg n "${name}" '.[$n]' <<<"${APP_VERSIONS}")
  fi
  if [[ -z "${version}" || "${version}" == "null" ]]; then
    echo "❌ ${name}: no resolved version." >&2
    exit 1
  fi
  dockerfile_default=$(jq -r '.dockerfile // .name' <<<"${app}")
  context=$(jq -r '.context // "."' <<<"${app}")
  app_platforms=$(jq -r '.platforms // "linux/amd64,linux/arm64"' <<<"${app}")
  cache_mode=$(jq -r '.cache_mode // "max"' <<<"${app}")
  app_scope=$(jq -r '.cache_scope // ""' <<<"${app}")
  etcd_build_env=$(jq -r '(.etcd_build_env // false) | tostring' <<<"${app}")

  if [[ "${app_platforms}" != *"linux/${arch}"* ]]; then
    echo "⏭  ${name}: platforms '${app_platforms}' exclude linux/${arch}"
    continue
  fi

  # Repo-level Dockerfile override + APP_NAME strip prefix (resolve-overrides).
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

  image="${REGISTRY}/${name}${IMAGE_SUFFIX}"
  arch_tag="${image}:${version}-${arch}"

  if docker manifest inspect "${arch_tag}" >/dev/null 2>&1; then
    echo "⏭  ${name}: image ${arch_tag} exists"
    continue
  fi

  ctx="${context}"
  if [[ "${etcd_build_env}" == "true" ]]; then
    # workspace-relative: the daemon resolves target paths inside the
    # transferred local context. .buildctx lives inside the workspace (next to
    # a "." context), so exclude it from the copy to avoid cp-ing a directory
    # into itself.
    rm -rf "${ctx_root}/${name}"
    mkdir -p "${ctx_root}/${name}"
    tar -C "${context}" --exclude='./.buildctx' -cf - . | tar -C "${ctx_root}/${name}" -xf -
    ctx=".buildctx/${name}"
    if [[ -s "${env_dir}/${name}.env" ]]; then
      cp "${env_dir}/${name}.env" "${ctx}/.env.production"
      echo "${name}: injected .env.production ($(wc -l < "${env_dir}/${name}.env") lines)"
    else
      echo "::warning::${name}: no build-env file — building without .env.production"
    fi
  fi

  scope="${app_scope:-${REPO_CACHE_SCOPE:-${name}}}-${arch}"
  targets_json=$(jq -cn \
    --argjson targets "${targets_json}" \
    --arg name "${name}" --arg ctx "${ctx}" --arg dockerfile "${dockerfile}" \
    --arg app_arg "${app_arg}" --arg tag "${arch_tag}" \
    --arg scope "${scope}" --arg mode "${cache_mode}" \
    --arg platform "${PLATFORMS#linux/}" \
    '$targets + {
      ($name): {
        "context": $ctx,
        "dockerfile": ("docker/Dockerfile." + $dockerfile),
        "args": {"APP_NAME": $app_arg},
        "platforms": ["linux/" + $platform],
        "tags": [$tag],
        "cache-from": ["type=gha,scope=" + $scope],
        "cache-to": ["type=gha,scope=" + $scope + ",mode=" + $mode]
      }
    }')
  targets=$((targets + 1))
  echo "→ ${name}: ${arch_tag} (APP_NAME=${app_arg}, scope=${scope})"
done < <(jq -c '.[]' <<<"${apps_json}")

# Bake needs a default group listing every target (bake-action invokes the
# default target when `targets` input is empty).
jq -n --argjson target "${targets_json}" \
  --argjson names "$(jq -c '[keys[]]' <<<"${targets_json}")" \
  '{target: $target, group: {"default": {targets: $names}}}' > "${bake_file}"
echo "Bake file ready: ${targets} target(s), platform ${PLATFORMS} → ${bake_file}"
{
  echo "targets=${targets}"
  echo "bake_file=${bake_file}"
} >> "${GITHUB_OUTPUT}"
