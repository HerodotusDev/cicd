# Advanced: Init Pods, GPU, Submodules, Manual Deploy, Runners, Troubleshooting

## Init pods (run-to-completion before main rollout)

Mark an app `init: true` in `cicd-inputs.yaml`. The pipeline builds it (or reuses another app's image via `image:`), then applies `k8s/<env>/<name>-pod.yaml` and waits for `phase=Succeeded` **before** any main app deploys.

- The manifest must be a **Pod or Job that terminates** (not a Deployment) — a long-running pod blocks the pipeline forever.
- Pod `metadata.name` **must equal** the app `name` (the pipeline deletes any existing pod by that name, applies, then `kubectl wait pod/<name>`).
- Use `image: <other-app>` to run a migration/seed using an already-built app image instead of building a dedicated one; the build step is then skipped.
- Use `<IMAGE>` placeholder for the image line, same as deployments.

Typical use: DB migrations that must finish before the server rolls out.

## GPU workloads (removed)

The home cluster has no GPU nodes; the old GCP GPU guide lives only on the
frozen `gcp-main` branch of the k8s repo.

## Submodules

The reusable `build-and-deploy.yaml` checks out submodules on every job. Control via the workflow_call input `submodules`: `true` (direct only, default), `recursive`, or `false`.

- Public submodules work with the default `GITHUB_TOKEN`.
- Private submodules require a PAT — pass `secrets: SUBMODULES_PAT` from the caller. It's used both for checkout and as the build `checkout_token`.

```yaml
jobs:
  call-deploy:
    uses: HerodotusDev/cicd/.github/workflows/build-and-deploy.yaml@main
    with:
      submodules: recursive
    secrets:
      SUBMODULES_PAT: ${{ secrets.SUBMODULES_PAT }}
```

## Redeploying / rolling back a version

There is no separate rollback workflow. To redeploy a specific image version, drive `build-and-deploy.yaml` with the desired version: set the `version_file` (or app version) to the already-built tag and re-run. Because the image already exists in the registry, the build step is skipped (`docker manifest inspect`) and the manifests are re-applied at that tag.

## Runner & secret environment (where credentials come from)

Jobs run on GitHub-hosted runners (`ubuntu-latest`). Cluster access is set up
per job by the **`cluster-access` composite action** (first step of every
kubectl/etcd-touching job):

- `WG_CONFIG` + `DEPLOYER_KUBECONFIG` are org secrets; deploying repos override
  `WG_CONFIG` with a **repo-level secret holding their own WG peer** (one peer
  per key — concurrent deploys from different repos each get their own tunnel;
  see the root README). A consumer repo does not create or pass these; the
  reusable workflow references them directly.
- ghcr login uses the caller's `GITHUB_TOKEN` — consumer workflows need
  `packages: write`.
- etcd credentials are read at deploy time from the in-namespace `daloc-etcd`
  secret and exported as `ETCD_USER`/`ETCD_PASSWORD` for that job only; nothing
  etcd-related is stored in GitHub.
- Tunnel-using matrix jobs (`deploy`, `deploy-init-pods`) run with
  `max-parallel: 1` so a repo never clashes with itself.

## Build-skip & tagging (the parts not covered elsewhere)

- The build is **skipped if `<image>:<version>` already exists** in the registry (`docker manifest inspect`). Bumping the version file is the only thing that forces a rebuild — re-running the same version reuses the existing image.
- The repo is git-tagged with the first app's resolved version, skipped if that tag already exists.

## Troubleshooting

| Symptom | Likely cause |
|---------|--------------|
| Job fails at "Wait for deployment rollout" but apply succeeded | Deployment `metadata.name` ≠ app `name`; or the new pods crash/aren't ready within `rollout_timeout` (default 500s). |
| Image didn't update after merge | Version file not bumped → existing tag reused, build skipped. Bump the version. |
| `ImagePullBackOff` | `ghcr-pull` secret missing in the namespace, or the PAT behind it lost access to the package. |
| Secret not present / app missing env | etcd key absent at `/<etcd_root>/<env>/<etcd_name>/.env`, or `etcd_root`/`etcd_name` mismatch. The pull step warns and continues. |
| Config edited but pods didn't restart | Hash unchanged (no real content change), or the configmap dir/etcd key wasn't actually updated. |
| Ingress 404/502 / cert not issuing | Ingress backend port ≠ Service port; Cloudflare DNS missing/proxied wrong; or a default-deny NetworkPolicy blocking ingress / the ACME HTTP-01 challenge (see manifests.md ingress notes). |
| Tunnel/port-forward failures (cluster-access step) | WG peer disabled on OPNsense, home internet down, or `daloc-etcd` not running in the namespace — check the etcd-forward log in the step output. |
| Run didn't trigger | Pushed to a non-`main`/`develop` branch, or commit message contains `[ci skip]`. |
| Init pod hangs the pipeline | Init manifest is a long-running Deployment/Pod instead of a job that reaches `Succeeded`. |

Always read the failing job's logs first — the actions echo the resolved image, etcd key, namespace, and hash decisions.
