#!/usr/bin/env bash
# Fetch an etcd key and render it as a Kubernetes Secret manifest.
#
# Replaces the old dataprocessor/etcd-pull container (amd64-only — broke on
# native arm64 runners, and the ghcr-hosted successor image is private, which
# consumer repos' GITHUB_TOKENs cannot pull). Runs etcdctl natively on the
# runner (binary cached per job in RUNNER_TEMP, downloaded per arch).
#
# Inputs (env): ETCD_HOST, ETCD_USER, ETCD_PASSWORD, ETCD_KEY,
#               APP_NAME, NAMESPACE, OUTPUT_FILE (path of the secret.yaml).
# Behavior on empty/missing key: exits 1 with a visible error — callers
# decide (the actions treat that as `found=false`; they must never bake an
# empty build env under a version tag the pipeline would later trust).
set -euo pipefail

: "${ETCD_HOST:?ETCD_HOST required}" "${ETCD_USER:?ETCD_USER required}" \
  "${ETCD_PASSWORD:?ETCD_PASSWORD required}" "${ETCD_KEY:?ETCD_KEY required}" \
  "${APP_NAME:?APP_NAME required}" "${NAMESPACE:?NAMESPACE required}" \
  "${OUTPUT_FILE:?OUTPUT_FILE required}"

case "$(uname -m)" in
  x86_64) etcd_arch=amd64 ;;
  aarch64 | arm64) etcd_arch=arm64 ;;
  *) echo "❌ Unsupported runner arch: $(uname -m)" >&2; exit 1 ;;
esac

etcdctl_bin="${RUNNER_TEMP:-/tmp}/etcdctl-${etcd_arch}/etcdctl"
if [[ ! -x "${etcdctl_bin}" ]]; then
  version=v3.5.21
  mkdir -p "$(dirname "${etcdctl_bin}")"
  curl -fsSL "https://github.com/etcd-io/etcd/releases/download/${version}/etcd-${version}-linux-${etcd_arch}.tar.gz" \
    | tar -xz -C "$(dirname "${etcdctl_bin}")" --strip-components=1 "etcd-${version}-linux-${etcd_arch}/etcdctl"
fi

values=$(ETCDCTL_API=3 "${etcdctl_bin}" \
  --endpoints="${ETCD_HOST}" \
  --user "${ETCD_USER}:${ETCD_PASSWORD}" \
  get "${ETCD_KEY}" --print-value-only)

if [[ -z "${values}" ]]; then
  echo "❌ No data fetched from etcd for key ${ETCD_KEY}" >&2
  exit 1
fi

secret_data=""
while IFS='=' read -r key value; do
  key=$(echo -n "${key}" | xargs)
  value=$(echo -n "${value}" | base64 -w0 | tr -d '\n\r')
  if [[ -n "${key}" && -n "${value}" ]]; then
    secret_data+="  ${key}: ${value}"$'\n'
  fi
done <<< "${values}"

mkdir -p "$(dirname "${OUTPUT_FILE}")"
cat > "${OUTPUT_FILE}" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${APP_NAME}-secret
  namespace: ${NAMESPACE}
type: Opaque
data:
${secret_data}
EOF

echo "✅ Secret manifest created: ${OUTPUT_FILE} ($(grep -c ':' <<< "${secret_data}") keys)"
