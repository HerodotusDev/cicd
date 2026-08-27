# `k8s/cicd-inputs.yaml` Reference

Parsed by the `load-inputs` action (a hand-rolled YAML→env reader, not a full YAML parser — keep the structure simple and 2-space indented). Every **top-level scalar** key becomes an environment variable for the workflow jobs; `app_names` drives the build/deploy matrix.

## Top-level keys

| Key | Required | Default | Notes |
|-----|----------|---------|-------|
| `namespace` | ✅ | — | Base namespace. Rewritten to `stg-<namespace>` on develop, `prod-<namespace>` on main. |
| `version_file` | — | `./package.json` | Fallback version source for apps that don't set their own. |
| `version_key` | — | first `version` field | Dot-path into the version file (e.g. `package.version`, or a TOML `[tool.poetry].version`). |
| `etcd_root` | — | repo name | Root segment of the etcd key path (`/<etcd_root>/<env>/<app>/.env`). |
| `dockerhub_project` | — | `dataprocessor` | Registry org/prefix. Workflow-level default; override here if needed. |

Any other top-level scalar you add also becomes an env var — only add ones the actions actually consume.

## `app_names`

Accepts three forms (mix freely):

```yaml
app_names:
  - myapp                    # plain string → all defaults
  - name: api                # object form → override per-app fields
    dockerfile: api
    version_file: ./api/Cargo.toml
  - name: migrate            # an init job (runs to completion before deploys)
    init: true
    image: api               # reuse api's image instead of building its own
```

### Per-app fields (object form)

| Field | Default | Effect |
|-------|---------|--------|
| `name` | — (required) | App identity. Drives image name, `<app>-secret`, configmap name, and **must equal `metadata.name`** of the Deployment / init Pod (rollout/wait look it up by this). |
| `version_file` | top-level `version_file` | Per-app version source. |
| `version_key` | top-level `version_key` | Per-app dot-path. |
| `dockerfile` | `<name>` | Builds `./docker/Dockerfile.<dockerfile>`. Set the same value on multiple apps to share one Dockerfile. |
| `context` (or `build_context`) | `.` | Docker build context dir. |
| `etcd_name` (or `etcd_app_name`) | `<name>` | etcd key segment, if it differs from the app name. |
| `manifest_name` | `<name>` | Filename prefix for `k8s/<env>/<manifest_name>-deployment.yaml` / `-ingress.yaml`. Use when the file is named differently from the app. |
| `init` | `false` | If true, app is built+run as an init pod (`<name>-pod.yaml`) before main apps; excluded from the main deploy matrix. |
| `image` | `<name>` | **Init pods only.** Reuse another app's built image instead of building a separate one; when set and ≠ name, the build step is skipped. |
| `etcd_build_env` | `false` | Pull a `.env` from etcd at **build time** and inject it as `.env.production` into the build context (see config reference). |
| `cache_mode` | `max` | BuildKit GHA cache export mode passed to `cache-to`: `min` (final image layers only) or `max` (all intermediate stages). |
| `cache_scope` | *(default BuildKit scope)* | Optional GHA cache scope key. Set per app so matrix builds do not overwrite each other's cache buckets. |

## Version resolution

`build-matrix` resolves each app's version from its version file at run time and uses it as the image tag:

- **JSON** (`package.json`): `version_key` is a dot-path via `jq getpath` (e.g. `package.version`); with no key, reads top-level `.version`.
- **TOML** (`Cargo.toml`): `version_key`'s last segment is the key and the preceding segments are the `[section]` (e.g. `tool.poetry.version` → key `version` in `[tool.poetry]`); with no key, the **first** `version =` line wins.
- A missing version file or unresolved version **fails the run**.
- The **first** app's version is the `primary_version` used for the git tag and for init pods.

## Gotchas

- This is a custom parser: avoid inline comments after values you depend on, flow-style mixed with block-style, and tabs. Stick to the shapes shown above.
- `name` is the source of truth for k8s object names. If `metadata.name` in the manifest doesn't match `name`, the rollout-status wait targets the wrong object and the job fails even though apply succeeded.
- Re-running without bumping the version is a no-op for the image (existing tag is reused) — but config changes still trigger a restart.
