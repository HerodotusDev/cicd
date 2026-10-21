## What the pipeline delivers
- Publishes a Docker image to `ghcr.io/herodotusdev/<app>-<env>:<version>` when the version changes (skips the build if the tag already exists — version bumps drive deploys).
- Images are **multi-arch manifest lists** (`linux/amd64` + `linux/arm64`) by default — the home cluster schedules pods onto both amd64 (`ms`) and arm64 (RPi) nodes, and the kubelet pulls whichever arch matches the node. See "Multi-arch builds" below.
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

## Required secrets (org-level defaults, per-repo overrides)
| Secret | Content |
|--------|---------|
| `WG_CONFIG` | wg-quick config of a `daloc-deployer` WireGuard peer (tunnel to the cluster proxy only) |
| `DEPLOYER_KUBECONFIG` | kubeconfig for the `capsule-users/daloc-deployer` ServiceAccount, pointing at the capsule proxy |

Both are org secrets shared by consumer repos. **WireGuard peers are one session per key** — a second handshake with the same key kills the first tunnel. Hence the convention:

- **Org secret `WG_CONFIG`** holds the default peer (used by the cicd smoke workflow).
- **Repos that deploy get their own peer + a repo-level `WG_CONFIG` secret** (repo secrets shadow org secrets): `daloc-deployer-monorepo`, `daloc-deployer-frontend-new`, `daloc-deployer-k8s`, … Create the OPNsense peer, put its config in the repo secret. With per-repo peers, two repos deploying at the same time is harmless — different keys, independent tunnels.
- Inside one repo, there is exactly **one tunnel per job**: the `build` job opens it only when an app pulls build-time env from etcd, and the `finalize` job opens it once for the whole deploy — all apps deploy in parallel through that single tunnel, so a repo can't clash with itself.

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

## Pipeline shape

Three jobs, four runner spawns total:

1. `prep` — branch guard, inputs, version resolution, app matrix.
2. `build` — one job per arch (`ubuntu-latest` / native `ubuntu-24.04-arm`); all apps build **in parallel inside the job** against one buildx daemon. Apps share the same Dockerfile DAG (per-app `APP_NAME` only affects the runtime stage), so BuildKit computes shared compile vertices once and fans the thin runtime stages out concurrently.
3. `finalize` — merges per-arch tags into manifest lists, creates the version tag, opens the cluster tunnel once, then deploys init pods + all apps **in parallel** (bounded by `deploy_concurrency`, default 5) sharing that single tunnel + etcd port-forward.

## Multi-arch builds
Images build per arch in parallel jobs — `linux/amd64` on `ubuntu-latest`, `linux/arm64` on the native `ubuntu-24.04-arm` runner — and push per-arch tags `<image>:<version>-<arch>`. `finalize` then assembles `<image>:<version>` + `:latest` as a manifest list, which is what the deploys apply; the kubelet resolves the platform per node, so Kubernetes never needs arch hints.

Caching: per-arch buildx GHA cache with scope resolution `app.cache_scope` → repo-level `cache_scope` (cicd-inputs top-level) → app name, always suffixed `-{arch}`. Repos with many apps sharing one Dockerfile should set the repo-level `cache_scope` — all apps then share one cache bucket per arch instead of duplicating the shared compile layers into a bucket per app (the GHA cache is 10 GB per repo, LRU-evicted after 7 days of no access). Dependency layers (`cargo-chef cook`, `bun install`) are cached per arch; a cold build of the daloc Rust workspace compiles in ~15 min per arch, warm builds faster. Per-app `platforms` in `cicd-inputs` excludes an arch from both build and merge.

Dockerfile requirements: base images (`FROM ...`) must be multi-arch manifests (all official rust/debian/node/bun images are) and must not hardcode `x86_64` paths or tools. `.github/workflows/multiarch-smoke.yaml` exercises the per-arch build + merge path on every push touching the build actions.

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
