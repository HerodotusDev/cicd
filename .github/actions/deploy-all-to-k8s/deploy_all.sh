#!/usr/bin/env bash
# Parallel per-app deploy through one cluster tunnel.
#
# The caller (build-and-deploy finalize job) has already opened the repo's
# WireGuard tunnel and the etcd port-forward via the cluster-access action;
# every worker below shares them. Init pods (run-to-completion) go first,
# then all deploy apps concurrently: configmap + etcd secret (hash-annotated,
# change-detected), manifest apply, rollout wait, config-change restart.
# Concurrency is bounded by the repo-level `deploy_concurrency` cicd-inputs
# key (default 5).
#
# Per-app behavior mirrors the older per-app composites
# (../create-configmap, ../pull-etcd-config, ../deploy-to-k8s,
# ../deploy-init-to-k8s) — those remain for consumers that call them
# directly; keep the logic in sync.
set -euo pipefail

: "${REGISTRY:?REGISTRY required}" "${MATRIX_DEPLOY:?MATRIX_DEPLOY required}" \
  "${APP_VERSIONS:?APP_VERSIONS required}" "${NAMESPACE:?NAMESPACE required}" \
  "${K8S_ENV:?K8S_ENV required}" "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY required}"
PRIMARY_VERSION="${PRIMARY_VERSION:-}"
IMAGE_SUFFIX="${IMAGE_SUFFIX:-}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-500}"
DEPLOY_CONCURRENCY="${deploy_concurrency:-5}"
ETCD_ROOT="${ETCD_ROOT:-}"
ETCD_USER="${ETCD_USER:-}"
ETCD_PASSWORD="${ETCD_PASSWORD:-}"
REPO="${GITHUB_REPOSITORY}"

for tool in jq yq kubectl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "❌ Error: $tool is required but not available." >&2; exit 1; }
done

overrides_file="${GITHUB_ACTION_PATH}/../resolve-overrides/overrides.yaml"
default_etcd_host="http://etcd.etcd.svc.cluster.local:2379"
etcd_pull="${GITHUB_ACTION_PATH}/../etcd-pull/pull.sh"
secret_dir="${RUNNER_TEMP:-/tmp}/deploy-env"
log_dir="${RUNNER_TEMP:-/tmp}/deploy-logs"
mkdir -p "${secret_dir}" "${log_dir}"

# ── Phase A (serial): pull etcd config for every app. Serial because pull.sh
# populates a shared etcdctl binary path on first use; the pulls are sub-second.
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

  echo "Fetching etcd config: /${ETCD_ROOT}/${K8S_ENV}/${etcd_name}/.env"
  ETCD_HOST="${etcd_host}" \
  ETCD_USER="${etcd_user}" \
  ETCD_PASSWORD="${etcd_password}" \
  ETCD_KEY="/${ETCD_ROOT}/${K8S_ENV}/${etcd_name}/.env" \
  APP_NAME="${etcd_name}" \
  NAMESPACE="${NAMESPACE}" \
  OUTPUT_FILE="${secret_dir}/${name}.secret.yaml" \
  bash "${etcd_pull}" || true

  if [[ ! -s "${secret_dir}/${name}.secret.yaml" ]]; then
    rm -f "${secret_dir}/${name}.secret.yaml"
    echo "::warning::No .env found at etcd key /${ETCD_ROOT}/${K8S_ENV}/${etcd_name}/.env — ${name} deploys without a secret"
  fi
done < <(jq -c '.[]' <<<"${MATRIX_DEPLOY}")

deploy_one() {
  set -euo pipefail
  local app="$1"
  local name etcd_name manifest_name version config_changed=false
  name=$(jq -r '.name' <<<"${app}")
  etcd_name=$(jq -r '.etcd_name // .name' <<<"${app}")
  manifest_name=$(jq -r '.manifest_name // .name' <<<"${app}")
  version=$(jq -r --arg n "${name}" '.[$n]' <<<"${APP_VERSIONS}")
  if [[ -z "${version}" || "${version}" == "null" ]]; then
    echo "❌ ${name}: no resolved version." >&2
    return 1
  fi

  # ConfigMap from k8s/<env>/<app>-configmap/ (if present), hash-annotated.
  local cm_dir="./k8s/${K8S_ENV}/${name}-configmap"
  if [[ -d "${cm_dir}" && -n "$(ls -A "${cm_dir}")" ]]; then
    local cm_hash cm_current
    cm_hash=$(find "${cm_dir}" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')
    if kubectl get configmap "${name}-configmap" -n "${NAMESPACE}" >/dev/null 2>&1; then
      cm_current=$(kubectl get configmap "${name}-configmap" -n "${NAMESPACE}" \
        -o jsonpath='{.metadata.annotations.configmap-hash}' 2>/dev/null || true)
      if [[ -z "${cm_current}" || "${cm_current}" != "${cm_hash}" ]]; then
        config_changed=true
      fi
    else
      config_changed=true
    fi
    kubectl create configmap "${name}-configmap" \
      --namespace "${NAMESPACE}" \
      $(for f in "${cm_dir}"/*; do echo -n "--from-file=$(basename "${f}")=${f} "; done) \
      --dry-run=client -o yaml | kubectl apply -f -
    kubectl annotate configmap "${name}-configmap" -n "${NAMESPACE}" \
      "configmap-hash=${cm_hash}" --overwrite
  fi

  # etcd-pulled secret, hash-annotated (pre-pulled in phase A).
  local secret_file="${secret_dir}/${name}.secret.yaml"
  if [[ -s "${secret_file}" ]]; then
    local secret_hash secret_current
    secret_hash=$(sha256sum "${secret_file}" | awk '{print $1}')
    if kubectl get secret "${name}-secret" -n "${NAMESPACE}" >/dev/null 2>&1; then
      secret_current=$(kubectl get secret "${name}-secret" -n "${NAMESPACE}" \
        -o jsonpath='{.metadata.annotations.secret-hash}' 2>/dev/null || true)
      if [[ -z "${secret_current}" || "${secret_current}" != "${secret_hash}" ]]; then
        config_changed=true
      fi
    else
      config_changed=true
    fi
    sed -i "/^metadata:/a\\  annotations:\\n    secret-hash: ${secret_hash}" "${secret_file}"
    kubectl apply -n "${NAMESPACE}" -f "${secret_file}"
  fi

  # Manifests: <IMAGE> placeholder → resolved image, apply, wait for rollout.
  local image="${REGISTRY}/${name}${IMAGE_SUFFIX}:${version}"
  local dep_file="./k8s/${K8S_ENV}/${manifest_name}-deployment.yaml"
  local ing_file="./k8s/${K8S_ENV}/${manifest_name}-ingress.yaml"
  if [[ -f "${dep_file}" ]]; then
    sed -i "s|<IMAGE>|${image}|g" "${dep_file}"
    kubectl apply --namespace "${NAMESPACE}" -f "${dep_file}"
  else
    echo "::warning::${name}: no deployment manifest at ${dep_file} — skipping apply"
  fi
  if [[ -f "${ing_file}" ]]; then
    sed -i "s|<IMAGE>|${image}|g" "${ing_file}"
    kubectl apply --namespace "${NAMESPACE}" -f "${ing_file}"
  fi
  if [[ -f "${dep_file}" ]]; then
    kubectl rollout status "deployment/${name}" --namespace "${NAMESPACE}" --timeout="${ROLLOUT_TIMEOUT}s"
  fi

  # Config changed but version didn't → restart to reload config.
  if [[ "${config_changed}" == "true" ]]; then
    echo "${name}: config changed — restarting deployment"
    kubectl rollout restart "deployment/${name}" -n "${NAMESPACE}"
    local also dep
    also=$(yq ".restart_also.\"${name}\" // [] | join(\",\")" "${overrides_file}")
    IFS=',' read -ra extra <<<"${also}"
    for dep in "${extra[@]}"; do
      [[ -z "${dep}" ]] && continue
      echo "${name}: also restarting ${dep}"
      kubectl rollout restart "deployment/${dep}" -n "${NAMESPACE}"
    done
    kubectl rollout status "deployment/${name}" --namespace "${NAMESPACE}" --timeout="${ROLLOUT_TIMEOUT}s"
    for dep in "${extra[@]}"; do
      [[ -z "${dep}" ]] && continue
      kubectl rollout status "deployment/${dep}" --namespace "${NAMESPACE}" --timeout="${ROLLOUT_TIMEOUT}s"
    done
  fi

  echo "✅ ${name}: deployed ${image}"
}

init_one() {
  set -euo pipefail
  local app="$1"
  local name image_name pod_manifest
  name=$(jq -r '.name' <<<"${app}")
  image_name=$(jq -r '.image // .name' <<<"${app}")
  pod_manifest="./k8s/${K8S_ENV}/${name}-pod.yaml"
  if [[ ! -f "${pod_manifest}" ]]; then
    echo "::warning::${name}: no init pod manifest at ${pod_manifest} — skipping"
    return 0
  fi
  local image="${REGISTRY}/${image_name}${IMAGE_SUFFIX}:${PRIMARY_VERSION}"
  sed -i "s|<IMAGE>|${image}|g" "${pod_manifest}"
  if kubectl get pod "${name}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    kubectl delete pod "${name}" -n "${NAMESPACE}"
  fi
  kubectl apply --namespace "${NAMESPACE}" -f "${pod_manifest}"
  kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${name}" \
    --namespace "${NAMESPACE}" --timeout="${ROLLOUT_TIMEOUT}s"
  echo "✅ ${name}: init pod succeeded"
}

run_workers() {
  # $1 = worker function name, $2 = concurrency, $3 = JSON array of apps.
  # Per-app output goes to a log file; failures are printed in full at the end.
  # Sets WORKERS_FAILED=1 if any worker failed. MUST be called outside a
  # tested context (no `||`, `if`, `$(...)`): errexit is suppressed inside
  # functions invoked that way, which would disable `set -e` in the worker
  # subshells and let deploys sail past failures.
  local worker="$1" conc="$2" apps_json="$3"
  local -a pids=() names=() app_lines=()
  local app i
  WORKERS_FAILED=0
  mapfile -t app_lines < <(jq -c '.[]' <<<"${apps_json}")
  for app in "${app_lines[@]}"; do
    local name
    name=$(jq -r '.name' <<<"${app}")
    names+=("${name}")
    echo "→ ${worker%%_*}: ${name}"
    ( "$worker" "${app}" ) >"${log_dir}/${name}.log" 2>&1 &
    pids+=($!)
    while (( $(jobs -rp | wc -l) >= conc )); do
      sleep 2
    done
  done
  for i in "${!pids[@]}"; do
    if ! wait "${pids[$i]}"; then
      WORKERS_FAILED=1
      echo "──────────────── ${names[$i]} (failed) ────────────────"
      cat "${log_dir}/${names[$i]}.log" || true
      echo "────────────────────────────────────────────────────────"
    else
      echo "ok  ${names[$i]}"
    fi
  done
}

export REGISTRY IMAGE_SUFFIX APP_VERSIONS PRIMARY_VERSION NAMESPACE K8S_ENV \
  ROLLOUT_TIMEOUT ETCD_ROOT ETCD_USER ETCD_PASSWORD REPO overrides_file secret_dir log_dir

echo "── Init pods ──────────────────────────────────────────────"
init_apps=$(jq -c '[.[] | select(.name != "__no_init__")]' <<<"${MATRIX_INIT}")
init_count=$(jq 'length' <<<"${init_apps}")
init_failed=0
if (( init_count > 0 )); then
  run_workers init_one "${DEPLOY_CONCURRENCY}" "${init_apps}"
  init_failed="${WORKERS_FAILED}"
  echo "Init pods done (failed=${init_failed})."
else
  echo "No init pods."
fi

deploy_count=$(jq 'length' <<<"${MATRIX_DEPLOY}")
echo "── Deploying ${deploy_count} app(s), concurrency ${DEPLOY_CONCURRENCY} ──"
deploy_failed=0
if (( deploy_count > 0 )); then
  run_workers deploy_one "${DEPLOY_CONCURRENCY}" "${MATRIX_DEPLOY}"
  deploy_failed="${WORKERS_FAILED}"
fi

echo "Deploy complete: ${deploy_count} app(s), ${init_count} init pod(s) (deploy_failed=${deploy_failed}, init_failed=${init_failed})."
if (( deploy_failed != 0 || init_failed != 0 )); then
  exit 1
fi
