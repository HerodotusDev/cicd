## What the pipeline delivers
- Publishes a Docker image when the version changes.
- Tags the repo with that version.
- Applies Kubernetes manifests for each app.
- Syncs ConfigMaps and optional etcd secrets before deployment.
- Re-runs init jobs (apps with `init: true`) ahead of the main rollout.
- If configmap or secret changed, but version has not, deployment will be restarted to load changes.

## Quick setup (based on l2-indexer)
1. Copy `.github/workflows/build-and-deploy.yaml` into your repository and adjust the `env` block.
2. Copy `examples/k8s` into your repo root. Edit manifests under `k8s/<env>/` to match your services.
3. Ensure a Dockerfile exists for every app (default path `docker/Dockerfile.<app>` unless you override `dockerfile`).
4. Fill out `k8s/cicd-inputs.yaml`.
5. Commit the version source files referenced in `version_file` (for example `Cargo.toml`, `package.json`).
6. Push to `develop` for staging deployment and to `main` for production. Other branches will be blocked.

## Etcd configuration
Upload the configuration file to etcd before the workflow runs. The workflow reads `/etcd_root/k8s_env/app_name/.env` and writes it into `<app_name>-secret`.
The secret is mounted into the container and configuration is accessible as system envs.

## ConfigMaps
If you place files in `k8s/<env>/<app>-configmap/`, they will be pulled into an config map object that can be mounted into the container as files.

## Tips
- When deploying a new app - a namespace has to be created.
- When deploying a new ingress - a dns entry has to created.
- Share a Dockerfile by assigning the same `dockerfile` value to multiple entries in `app_names`.
- Each app can use shared version source or a dedicated one, to be set in cicd_inputs.
- Mark init-only apps with `init: true`; they will be build and deployed before standard apps.
  Those apps need to run to completition, else they will block the pipeline - so they have to be a job or pod, not a deployment.
