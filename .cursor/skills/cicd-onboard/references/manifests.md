# Manifest Reference (`k8s/<env>/`)

The deploy action expects, per app and per environment (`stg`, `prod`):

```
k8s/
  stg/
    <manifest_name>-deployment.yaml   # required (Deployment + usually Service)
    <manifest_name>-ingress.yaml      # optional, only if public-facing
    <name>-pod.yaml                   # only for init: true apps
    <name>-configmap/                 # optional dir of files → ConfigMap
  prod/
    ... same layout ...
```

`<manifest_name>` defaults to the app `name` (override with the `manifest_name` input field). Create only the env dirs you deploy to — a prod-only repo has just `k8s/prod/`. If you use both, keep them structurally in sync; they should differ only in replicas/resources/hosts.

## The `<IMAGE>` placeholder (mandatory)

The container image line **must** be the literal string `<IMAGE>`:

```yaml
containers:
  - name: myapp
    image: <IMAGE>      # sed-replaced at deploy with dataprocessor/<prefix><name>:<version>
```

The deploy action runs `sed -i "s|<IMAGE>|dataprocessor/<prefix><app>:<tag>|g"` before applying. On `main` there is no prefix (prod image); on `develop` it's `stg-`.

## Naming rules that must hold

- **Deployment `metadata.name` == app `name`.** The pipeline waits with `kubectl rollout status deployment/<name>` and (on config change) `kubectl rollout restart deployment/<name>`. A mismatch fails the job after apply.
- **Init Pod `metadata.name` == app `name`** — `kubectl wait pod/<name> --for=...Succeeded`.
- The Service name is your choice but must match what the Ingress `backend.service.name` references.

## Deployment + Service template

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp                  # MUST equal app name
spec:
  replicas: 1
  selector:
    matchLabels: { app: myapp }
  template:
    metadata:
      labels: { app: myapp }
    spec:
      imagePullSecrets:
        - name: dockerhub-secret   # must pre-exist in the namespace
      containers:
        - name: myapp
          image: <IMAGE>
          envFrom:
            - secretRef:
                name: myapp-secret   # created from etcd (see config.md); omit if unused
          ports:
            - containerPort: 8040
          resources:
            requests: { cpu: '100m', memory: '128Mi' }
            limits:   { cpu: '1',    memory: '2G' }
          livenessProbe:
            httpGet: { path: /is-alive, port: 8040 }
            initialDelaySeconds: 10
            periodSeconds: 10
          readinessProbe:
            httpGet: { path: /is-alive, port: 8040 }
            initialDelaySeconds: 5
            periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: myapp-service
spec:
  selector: { app: myapp }
  ports:
    - port: 8040
      targetPort: 8040
```

Need persistence? Add a PVC with `storageClassName: lh-common` (the cluster's default Longhorn class, `ReadWriteOnce`) and mount it.

## Ingress template (public-facing apps)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myapp-ingress
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    # optional: 308 HTTP→HTTPS redirect. Omit if you don't need it (the reference repo does).
    traefik.ingress.kubernetes.io/router.middlewares: kube-system-redirect-https@kubernetescrd
spec:
  ingressClassName: traefik
  tls:
    - hosts: [myapp.api.herodotus.cloud]
      secretName: myapp-tls
  rules:
    - host: myapp.api.herodotus.cloud
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: myapp-service
                port:
                  number: 8040     # MUST match the Service port
```

A new host also needs a public DNS A record pointing at the shared Traefik load-balancer IP (ask infra for the current value). If the target namespace uses a default-deny NetworkPolicy, ingress and the ACME HTTP-01 challenge must be explicitly allowed or the TLS certificate will not issue -- check the namespace policy with infra.

### Geoblocked hosts

Fronted by the geoblock edge LB (Cloud Armor GeoIP)? That host's router needs an origin-lock header rather than a plain `Ingress`. Setup is infra-driven — see the private **k8s** repo (`ansible/playbooks/gcp/GEOBLOCK.md`).

## Gotchas worth fixing when you template from existing repos

The cicd repo's `examples/k8s/**` (and some live repos) carry patterns worth correcting:

1. **Ingress backend port must match the Service port.** The cicd *example* exposes Service `8040` but points the Ingress backend at `8080` — that 502s. (The reference `l2-indexer` ingress gets it right at `8000`.) Always match them.
2. **`spec.ingressClassName: traefik` is widely written as an annotation.** Both the cicd example and the live `l2-indexer` ingress put it under `metadata.annotations`, with no `spec.ingressClassName` field — it works *only because Traefik is the cluster's default IngressClass*. It's not fatal, but prefer the real `spec.ingressClassName` field (as shown above) so the binding is explicit rather than relying on the default.
