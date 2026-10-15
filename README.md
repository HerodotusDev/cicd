## What the pipeline delivers
- Publishes a Docker image to `ghcr.io/herodotusdev/<app>-<env>:<version>` when the version changes (skips the build if the tag already exists — version bumps drive deploys).
- Tags the repo with that version.
- Opens a WireGuard tunnel to the home k3s cluster and applies Kubernetes manifests for each app as the `daloc-deployer` identity.
- Syncs configuration from etcd (over the tunnel, via port-forward) and configmap dirs before deployment.
- Runs init jobs (apps with `init: true`) ahead of the main rollout.
- If configmap or secret changed, but version has not, deployment will be restarted to load changes.
- Waits for deployment rollout.

## Branch → environment mapping
| Branch | namespace | image |
|--------|-----------|-------|
| `main` | `<namespace>-prod` (e.g. `daloc-prod`) | `ghcr.io/herodotusdev/<app>-prod` |
| `develop` | `<namespace>-stg` | `ghcr.io/herodotusdev/<app>-stg` |

Other branches are blocked. Environments are à la carte: wire only the branches you use; create the target namespace (as the tenant owner) before the first deploy.

## Required secrets (org-level, shared)
| Secret | Content |
|--------|---------|
| `WG_CONFIG` | wg-quick config of the `daloc-deployer` WireGuard peer (tunnel to the cluster proxy only) |
| `DEPLOYER_KUBECONFIG` | kubeconfig for the `capsule-users/daloc-deployer` ServiceAccount, pointing at the capsule proxy |

The pipeline logs in to ghcr with the caller's `GITHUB_TOKEN` — consumer workflows need `packages: write`. etcd credentials are read at deploy time from the in-namespace `daloc-etcd` secret; no etcd secret lives in GitHub.

## Quick setup (consumer repo)
1. Copy `examples/workflows/build-and-deploy-workflow.yaml` into `.github/workflows/`. Add `packages: write` to `permissions`. Add `[ci skip]` to a commit message to avoid triggering cicd.
2. Copy `examples/k8s` into your repo root. Edit manifests under `k8s/<env>/` to match your services (ingress TLS uses Traefik `certresolver=default` — no cert-manager on the home cluster).
3. Ensure a Dockerfile exists for every app (default path `docker/Dockerfile.<app>` unless you override `dockerfile`).
4. Fill out `k8s/cicd-inputs.yaml`.
5. Commit the version source files referenced in `version_file` (for example `Cargo.toml`, `package.json`). Bumping the version triggers the deploy.
6. Ensure org secrets `WG_CONFIG` + `DEPLOYER_KUBECONFIG` exist and cover your repo. Push to `main` (prod) or `develop` (stg).

## AI-assisted setup (cicd-onboard skill)
This repo ships a `cicd-onboard` skill (`.cursor/skills/cicd-onboard/`) that lets an AI coding agent (Claude Code, Cursor, etc.) wire CI/CD into an app repo for you. Install it with the bundled script:

```bash
# global: symlink into ~/.claude + ~/.agents (default; tracks this checkout)
tools/install-skill.sh

# into a specific app repo's .claude/.agents/.cursor
tools/install-skill.sh --repo /path/to/app-repo

# copy instead of symlink (portable, but goes stale on cicd updates)
tools/install-skill.sh --copy
tools/install-skill.sh --repo /path/to/app-repo --copy

tools/install-skill.sh --help   # full usage
```

Once installed, ask the agent to onboard the repo and it follows the skill.

## Etcd configuration
Upload the configuration file to etcd before the workflow runs. The workflow reads `/etcd_root/k8s_env/app_name/.env` and writes it into `<app_name>-secret`.
etcd lives in the deploy namespace (`daloc-etcd`); CI reaches it over the WireGuard tunnel via `kubectl port-forward` (the `cluster-access` action sets that up). The secret is mounted into the container and configuration is accessible as system envs.

## ConfigMaps
If you place files in `k8s/<env>/<app>-configmap/`, they will be pulled into a config map object that can be mounted into the container as files.

## Tips
- When deploying a new app — the namespace must exist first (created by the tenant owner through the capsule proxy).
- When deploying a new ingress — a Cloudflare DNS record (proxied) has to point the host at the home WAN.
- Pipeline can be triggered manually via GitHub UI — not only by a commit (main/develop only).
- Share a Dockerfile by assigning the same `dockerfile` value to multiple entries in `app_names`.
- Each app can use a shared version source or a dedicated one, to be set in cicd_inputs.
- If the pipeline failed, check the logs before messaging ppl :)
- Mark init-only apps with `init: true`; they will be built and deployed before standard apps.
  Those apps need to run to completion, else they will block the pipeline — so they have to be a job or pod, not a deployment.
- Deploys need the home internet up (the tunnel is in the path); failures are retryable and apply is idempotent.
