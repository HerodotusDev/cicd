## etcd key layout
The pull step reads `/etcd_root/k8s_env/app_name/.env`. Override any of those pieces using `etcd_root`, per-app `etcd_name`, or by setting `k8s_env`, but pls try to keep the standard.


## Quick setup 
1. Copy `.github/workflows/build-and-deploy.yaml` into your repository and adjust the `env` block.
2. Copy `examples/k8s` into your repo root. Edit manifests under `k8s/<env>/` to match your services.
3. Ensure a Dockerfile exists for every app (default path `docker/Dockerfile.<app>` unless you override `dockerfile`).
4. Fill out `k8s/cicd-inputs.yaml` using the commented template mentioned above.
5. Commit the version source files referenced in `version_file` (for example `Cargo.toml`, `package.json`).
6. Push to `develop` to exercise the staging path and to `main` for production defaults. 

## Tips
- Share a Dockerfile by assigning the same `dockerfile` value to multiple entries in `app_names`.
- Mark apps for the init pipeline by setting `init: true` inside the relevant `app_names` entry; defaults to false.
