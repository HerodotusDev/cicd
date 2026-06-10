# Configuration: etcd Secrets & ConfigMaps

Two independent mechanisms feed config into a deployment. Both compute a content hash; if it changed since the last deploy, the pipeline `rollout restart`s the deployment so the new config is picked up even when the image version didn't change.

## etcd → `<app>-secret`

Runtime secrets/env live in the team's external config store, **not** in the repo. At deploy time the pipeline reads each app's config from the key:

```
/<etcd_root>/<k8s_env>/<etcd_name>/.env
```

- `etcd_root` = the `etcd_root` input, defaulting to the repo name.
- `k8s_env` = `stg` or `prod` (from the branch).
- `etcd_name` = the app's `etcd_name` field, defaulting to its `name`.

> Populating that key is done out-of-band with the team's internal config-store tooling. That procedure is **intentionally not documented here** (this repo is public) — get it from internal docs / a teammate. This skill only covers the deploy-side contract: which key the pipeline reads and what it does with it.

The `pull-etcd-config` action fetches that key and `kubectl apply`s it as a Secret named `<app>-secret` (annotated with a `secret-hash`). Mount it in the Deployment:

```yaml
envFrom:
  - secretRef:
      name: myapp-secret
```

- If the key is **absent**, the step warns and skips (no secret, no failure) — fine for apps with no secrets.
- The store endpoint is resolved by the pipeline (per namespace); you don't configure it from the app repo.
- Changed secret content → `rollout restart`. Special case in the deploy action: restarting `atlantic-server` also restarts `atlantic-workers`.

The `.env` is plain `KEY=VALUE` lines, e.g.:

```
MYAPP_API_KEY=...
REDIS_HOST=myapp-master.myapp.svc.cluster.local
REDIS_PORT=6379
```

## Build-time `.env` (`etcd_build_env: true`)

Some images need secrets at **build** time (baked into the image). Set `etcd_build_env: true` on the app. The `pull-etcd-build-env` action fetches the same etcd key, decodes it, and the build writes it into the build context as `.env.production` before `docker build`. Use sparingly — anything baked into an image is shipped in that image.

## File ConfigMaps → `<app>-configmap`

Drop any files into `k8s/<env>/<app>-configmap/` and the `create-configmap` action creates/updates a ConfigMap named `<app>-configmap` (one key per filename), annotated with a `configmap-hash`. Mount it as files:

```yaml
volumes:
  - name: config
    configMap:
      name: myapp-configmap
# ...
volumeMounts:
  - name: config
    mountPath: /etc/myapp
```

- No directory or an empty one → step is skipped (`config_changed=false`).
- Changed file content → `rollout restart`, same as secrets.

## Quick mental check

> Bumping the **version file** rebuilds + redeploys the image. Changing the **etcd `.env`** or **configmap files** (with the version unchanged) re-applies the secret/configmap and restarts the deployment. Doing neither is a no-op.
