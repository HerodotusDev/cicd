#!/bin/bash
set -e  # Exit on error

# Ensure APP_NAME and NAMESPACE are set
if [[ -z "$APP_NAME" || -z "$NAMESPACE" ]]; then
  echo "Error: APP_NAME or NAMESPACE is not set!"
  exit 1
fi

echo "Fetching ETCD configuration..."
ETCD_VALUES=$(ETCDCTL_API=3 etcdctl \
  --endpoints="$ETCD_HOST" \
  --user "$ETCD_USER:$ETCD_PASSWORD" \
  get "$ETCD_KEY" --print-value-only 2>/dev/null)

if [[ -z "$ETCD_VALUES" ]]; then
  echo "Error: No data fetched from etcd!"
  exit 1
fi

# Store values in a temporary file
echo "$ETCD_VALUES" > /app/etcd_values.env
chmod 600 /app/etcd_values.env  # Secure the file

echo "Preparing Kubernetes Secret manifest..."
SECRET_DATA=""

while IFS='=' read -r key value; do
  key=$(echo -n "$key" | xargs)  # Trim whitespace
  value=$(echo -n "$value" | base64 -w0 | tr -d '\n' | tr -d '\r')  # Base64 encode & remove newlines
  if [[ ! -z "$key" && ! -z "$value" ]]; then
    SECRET_DATA+="  $key: $value\n"  # Fix: Use printf-like newline handling
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
$(echo -e "$SECRET_DATA" | sed 's/^/  /')  # Fix: Correct YAML indentation
EOF

echo "✅ Secret manifest created successfully: /output/secret.yaml"
