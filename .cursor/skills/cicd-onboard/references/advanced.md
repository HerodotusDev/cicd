# Advanced: Init Pods, GPU, Submodules, Manual Deploy, Runners, Troubleshooting

## Init pods (run-to-completion before main rollout)

Mark an app `init: true` in `cicd-inputs.yaml`. The pipeline builds it (or reuses another app's image via `image:`), then applies `k8s/<env>/<name>-pod.yaml` and waits for `phase=Succeeded` **before** any main app deploys.

- The manifest must be a **Pod or Job that terminates** (not a Deployment) — a long-running pod blocks the pipeline forever.
- Pod `metadata.name` **must equal** the app `name` (the pipeline deletes any existing pod by that name, applies, then `kubectl wait pod/<name>`).
- Use `image: <other-app>` to run a migration/seed using an already-built app image instead of building a dedicated one; the build step is then skipped.
- Use `<IMAGE>` placeholder for the image line, same as deployments.

Typical use: DB migrations that must finish before the server rolls out.

## GPU workloads

Full guide lives in the cicd repo at `examples/gpu.md`. Essentials:

- Deployment pod spec needs `runtimeClassName: nvidia`, a toleration for the `kind=gpu-worker:NoSchedule` taint, and `resources.limits."nvidia.com/gpu": "1"`.
- Dockerfile: base on `nvidia/cuda:<ver>-{base|runtime|devel}-ubuntu22.04`; **never install NVIDIA drivers** (injected at runtime by the RuntimeClass).
- GPU nodes are MIG-managed and may be scaled to zero; the first GPU pod can take minutes while a node spins up. Cluster-side scaling is outside this skill.

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

The reusable workflow runs on self-hosted runners (`gcp-arc-runners`) that inject the
cluster-wide infra credentials it needs as `env.ARC_*` — a consumer repo does **not**
set these. kubectl auth is in-cluster (the runner runs inside the cluster); there's no
kubeconfig to manage. The only secret a consumer may need to pass is `SUBMODULES_PAT`
(private submodules).

> What the runner's `ARC_*` values are, and how they're stored, deployed, and rotated,
> lives in the **private k8s repo** (`kubernetes/SECRETS.md`).

## Build-skip & tagging (the parts not covered elsewhere)

- The build is **skipped if `<image>:<version>` already exists** in the registry (`docker manifest inspect`). Bumping the version file is the only thing that forces a rebuild — re-running the same version reuses the existing image.
- At build time, branches other than main/develop get a `dev-` image prefix (the deploy step only ever uses `stg-`/none, so dev images are build-only artifacts).
- The repo is git-tagged with the first app's resolved version, skipped if that tag already exists.

## Troubleshooting

| Symptom | Likely cause |
|---------|--------------|
| Job fails at "Wait for deployment rollout" but apply succeeded | Deployment `metadata.name` ≠ app `name`; or the new pods crash/aren't ready within `rollout_timeout` (default 500s). |
| Image didn't update after merge | Version file not bumped → existing tag reused, build skipped. Bump the version. |
| `ImagePullBackOff` | `dockerhub-secret` missing in the namespace, or pushing to the wrong env prefix (deployed from `develop` expects `stg-<app>`). |
| Secret not present / app missing env | etcd key absent at `/<etcd_root>/<env>/<etcd_name>/.env`, or `etcd_root`/`etcd_name` mismatch. The pull step warns and continues. |
| Config edited but pods didn't restart | Hash unchanged (no real content change), or the configmap dir/etcd key wasn't actually updated. |
| Ingress 404/502 / cert not issuing | Ingress backend port ≠ Service port; namespace missing its DNS A record; or a default-deny NetworkPolicy blocking ingress / the ACME HTTP-01 challenge (see manifests.md ingress notes). |
| Run didn't trigger | Pushed to a non-`main`/`develop` branch, or commit message contains `[ci skip]`. |
| Init pod hangs the pipeline | Init manifest is a long-running Deployment/Pod instead of a job that reaches `Succeeded`. |

Always read the failing job's logs first — the actions echo the resolved image, etcd key, namespace, and hash decisions.
