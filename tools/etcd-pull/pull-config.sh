#!/bin/bash
set -euo pipefail  # Exit on error, unset vars, and errors in pipes

log_error() {
  echo "[ERROR] $1" >&2
}

log_info() {
  echo "[INFO] $1"
}

# Ensure APP_NAME and NAMESPACE are set
if [[ -z "${APP_NAME:-}" || -z "${NAMESPACE:-}" ]]; then
  log_error "APP_NAME or NAMESPACE is not set!"
  exit 1
fi

if [[ -z "${ETCD_HOST:-}" || -z "${ETCD_USER:-}" || -z "${ETCD_KEY:-}" ]]; then
  log_error "ETCD_HOST, ETCD_USER, or ETCD_KEY is not set!"
  exit 1
fi

log_info "Fetching ETCD configuration from $ETCD_HOST..."

ETCD_VALUES=$(ETCDCTL_API=3 etcdctl \
  --endpoints="$ETCD_HOST" \
  --user "$ETCD_USER:${ETCD_PASSWORD:-}" \
  get "$ETCD_KEY" --print-value-only 2>/dev/null) || {
    log_error "Failed to fetch data from etcd endpoint!"
    exit 1
}

if [[ -z "$ETCD_VALUES" ]]; then
  log_error "No data fetched from etcd for key: $ETCD_KEY"
  exit 1
fi

# Store values securely in a temporary file
echo "$ETCD_VALUES" > /app/etcd_values.env
chmod 600 /app/etcd_values.env

log_info "ETCD values stored in /app/etcd_values.env"

# Prepare Kubernetes Secret manifest
log_info "Preparing Kubernetes Secret manifest..."
SECRET_DATA=""

while IFS='=' read -r key value || [[ -n "$key" ]]; do
  key=$(echo -n "$key" | xargs)  # Trim whitespace
  value=$(echo -n "$value" | base64 -w0 | tr -d '\n\r')  # Base64 encode & remove newlines
  if [[ -n "$key" && -n "$value" ]]; then
    SECRET_DATA+="  $key: $value\n"
  fi
done < /app/etcd_values.env

# Ensure APP_NAME and NAMESPACE are correctly formatted for YAML
APP_NAME_CLEAN=$(echo -n "$APP_NAME" | xargs)
NAMESPACE_CLEAN=$(echo -n "$NAMESPACE" | xargs)

# Generate Secret YAML
cat > /output/secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${APP_NAME_CLEAN}-secret
  namespace: ${NAMESPACE_CLEAN}
type: Opaque
data:
$(echo -e "$SECRET_DATA" | sed 's/^/  /')
EOF

log_info "✅ Secret manifest successfully created at: /output/secret.yaml"
