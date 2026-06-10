---
name: cicd-onboard
description: >
  Onboard an application repo to the Herodotus shared CI/CD pipeline
  (HerodotusDev/cicd reusable GitHub Actions workflows). Use when adding
  build/deploy automation to a new service, wiring a repo to deploy to the
  k3s cluster, scaffolding k8s/<env> manifests, cicd-inputs.yaml, Dockerfiles,
  configuring etcd-backed secrets or configmaps, or adding a second app /
  init pod / GPU workload to an existing pipeline.
---

# Herodotus CI/CD Onboarding

How to add the shared build-and-deploy pipeline to an **app repo**. The heavy lifting lives in `HerodotusDev/cicd` (reusable workflows + composite actions); a consumer repo only supplies a thin workflow stub plus manifests, Dockerfiles, and an inputs file.

## How the pipeline works (mental model)

`develop`/`main` push (or manual `workflow_dispatch`) triggers the caller's workflow, which calls `HerodotusDev/cicd/.github/workflows/build-and-deploy.yaml@main`. That reusable workflow:

1. **define-matrix** — parses `k8s/cicd-inputs.yaml`, resolves each app's version from its version file, builds the app/deploy/init matrices.
2. **build-and-push-image** — per app: builds `docker/Dockerfile.<app>`, pushes `dataprocessor/<prefix><app>:<version>` (and `:latest`). **Skips the build if that image:tag already exists** — so deploys are driven by bumping the version file.
3. **create-git-tag** — tags the repo with the primary (first app's) version if absent.
4. **build/deploy init pods** — apps marked `init: true` build and run to completion *before* the main rollout.
5. **deploy** — syncs configmap + etcd secret, sed-replaces `<IMAGE>` in the manifest, `kubectl apply`s deployment + ingress, waits for rollout. If the secret/configmap content changed, it `rollout restart`s the deployment.

**Branch → environment mapping** (done by the `load-inputs` action):

| Branch | `k8s_env` | namespace | image prefix |
|--------|-----------|-----------|--------------|
| `develop` (or `gcp-develop`) | `stg` | `stg-<namespace>` | `stg-` |
| `main` (or `gcp-main`) | `prod` | `prod-<namespace>` | *(none)* |

Environments are **à la carte**: you create only the `k8s/<env>/` dirs you actually deploy to and wire only the matching branches in your stub's `on.push.branches`. A repo that ships straight to prod uses just `k8s/prod/` and triggers on `main` (this is what the reference `l2-indexer` repo does). Add `develop` + `k8s/stg/` only if you want a staging path.

> **build-and-deploy.yaml has no internal branch guard.** The main/develop restriction comes only from the `on.push.branches` in your stub. The `load-inputs` action rewrites `namespace`/`k8s_env` *only* for main/develop (and the `gcp-` variants); on any other branch `k8s_env` is empty, so manifest paths resolve to `./k8s//…` and break. Don't `workflow_dispatch` this workflow from a feature branch. (The separate `deploy.yaml` *does* enforce main/develop via `guard-branch`.)

## Onboarding checklist

Run these against the **target app repo** (not the cicd repo). Most paths are conventions the pipeline expects exactly.

1. **Workflow stub** → `.github/workflows/build-and-deploy.yaml`. Copy `examples/workflows/build-and-deploy-workflow.yaml` from the cicd repo verbatim — it's ~12 lines and rarely needs edits:
   ```yaml
   name: Build and deploy
   on:
     workflow_dispatch:
     push:
       branches: [main, develop]
   permissions:
     contents: write
   jobs:
     call-deploy:
       uses: HerodotusDev/cicd/.github/workflows/build-and-deploy.yaml@main
   ```
   Add `[ci skip]` to a commit message to suppress a run. Private submodules → pass `secrets: SUBMODULES_PAT: ${{ secrets.SUBMODULES_PAT }}` and `with: submodules: recursive`.

2. **`k8s/cicd-inputs.yaml`** — the one file you always edit. Minimum:
   ```yaml
   namespace: myapp          # becomes stg-myapp / prod-myapp
   version_file: ./Cargo.toml   # or ./package.json (default)
   app_names:
     - name: myapp
   ```
   Full per-app field reference → [references/cicd-inputs.md](references/cicd-inputs.md).

3. **Manifests** → `k8s/<env>/<app>-deployment.yaml` for each env you deploy to (+ matching `-ingress.yaml` only if public-facing; workers/jobs need none). The container image MUST be the literal placeholder `image: <IMAGE>`. Templates, the required naming rules, and example gotchas → [references/manifests.md](references/manifests.md).

4. **Dockerfile** → `docker/Dockerfile.<app>` for every app (the suffix defaults to the app `name`; override with the `dockerfile` field to share one). Build context defaults to repo root.

5. **Version file** — commit the file referenced by `version_file` (`package.json` `.version`, or `Cargo.toml` `[package] version`). **Bumping this version is what causes a redeploy.** See version resolution rules in [references/cicd-inputs.md](references/cicd-inputs.md#version-resolution).

6. **Config (if the app needs env/secrets)** — upload the env to etcd (→ `<app>-secret`) and/or drop files in `k8s/<env>/<app>-configmap/`. Wiring, paths, and change-triggered restarts → [references/config.md](references/config.md).

7. **Cluster prerequisites (one-time, manual, outside the repo):**
   - Create the namespace (`stg-<namespace>` / `prod-<namespace>`) before the first deploy.
   - Ensure the `dockerhub-secret` image-pull secret exists in that namespace.
   - For a new ingress host, create the public DNS A record pointing at the shared Traefik load-balancer IP (ask infra for the current value).

8. **Push** — `develop` for staging, `main` for production. Watch the Actions run; check job logs before escalating.

## When to reach for references

- Per-app inputs schema, version resolution, multi-app / shared-version setups → [references/cicd-inputs.md](references/cicd-inputs.md)
- Deployment / Service / Ingress / PVC templates, naming rules, `<IMAGE>` placeholder, example bugs → [references/manifests.md](references/manifests.md)
- etcd secrets, build-time `.env`, configmaps, change detection & restart behavior → [references/config.md](references/config.md)
- Init pods, GPU workloads, submodules, runner/secret environment, troubleshooting → [references/advanced.md](references/advanced.md)
