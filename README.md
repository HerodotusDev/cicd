# cicd
Repository for generic cicd templates




example values

```yaml
app_name: "auth-billing"
replicas: 1


etcd_url: "https://config.api.herodotus.cloud:2379"
etcd_keys: "/auth-billing/config.stage.json"
secret_name: "auth-billing-secret"

container_port: 8040
service_port: 8040

resources:
  requests:
    cpu: "100m"
    memory: "128Mi"
  limits:
    cpu: "1"
    memory: "2G"

liveness_probe:
  initialDelaySeconds: 10
  periodSeconds: 10

readiness_probe:
  initialDelaySeconds: 5
  periodSeconds: 5

healthcheck_path: "/is-alive"
```