
# Repository for generic cicd templates.

## Importing workflows

To import workflows, copy the [examples/workflows](./examples/workflows) directory to you repo .github dir on main branch.

While doing initial ci commits, include a [ci skip ] in commit message, to skip running the build-and-deploy workflow.
  
  

Trigger conditions can be set per repo in workflow file 

[ How to set triggers ](https://docs.github.com/en/actions/writing-workflows/choosing-when-your-workflow-runs/events-that-trigger-workflows)

## Defining k8s env


k8s_env variable in workflow defines which dir under k8s will be used as base for deployment.

e.g.

```yaml
k8s_env: stage
```
will make cicd use k8s/stage dir 

```yaml
k8s_env: prod
```
will make cicd use k8s/prod dir 
```yaml
k8s_env: leftmywaller
```
will make cicd use k8s/letmywallet dir


## Build and deploy 

   Runs either on push to main branch, or on manual trigger.

   Steps:

    - extract version from package.json / cargo.toml - file specified in cicd_inputs as version_file
    - if a docker image tagged with this version hasn't been pushed to registry, build it
    - if a git tag with this version doesn't exist, tag the commit 
    - deploy k8s manifests, using version read from version_file
    - if etcd-pull is true, pull config from etcd and inject it into k8s secret, if changed restart deployment by adding checksum annotation


   If there was a change in version, but not in manifests - job will build and run a new version.

   If there was no change in version, but there was a change in manifest - job will run new manifests with the latest version.

   If there was no changes in manifests, nor in version, job will do nothing.

## Deploy

  Runs on manual trigger and requires a docker image tag to run.

  Deploys given image to k8s


## Dockerfile

To build a dockerimage a Dockerfile is needed.

It has to situated in [examples/docker](./examples/docker) dir

and be named in convertion of 

```yaml
Dockerfile.app_name
```
corresponing to app_names provided in [cicd-inputs](./examples/k8s/cicd-inputs.yaml)

e.g.

```yaml
Dockerfile.example
```

in case of monorepo, multiple Dockerfiles have to be provided, corresponding to app_names e.g.

```yaml
Dockerfile.example1
Dockerfile.example2
```
## Importing K8s templates

To enable k8s deploy, copy the [examples/k8s](./examples/k8s) directory to you repo root dir.

[cicd-inputs](./examples/k8s/cicd-inputs.yaml) file specifies variables to be passed to following pipelines and has to be set.

In case of monorepo it required to specify app_name list in format:

```yaml
app_names: ["example1","example2"]
```
or in case of single app

```yaml
app_names: ["example1"]
```

Manifest files have to named in convention of app_name-object.yaml  e.g.

```yaml
example-deployment.yaml
```
```yaml
example-ingress.yaml
```



## Enabling etcd pull

To enable pulling configuration from etcd, following line have to be added / uncommented from [cicd-inputs](./examples/k8s/cicd-inputs.yaml):

The key path will be determined by namespace and app name e.g

  example_namespace/example_app/envs/example_key

```yaml

pull_etcd_config: true              # toggle etcd pull flag
etcd_key: .env.stage                # key to be pulled 

```
The file to be pulled has to be in key=value format coded as yaml.

[etcd key example ](./examples/etcd/.env.stage)

Defined key will be pulled from etcd during workflow execution, and saved to a k8s secret named as {{ app_name }}-secret.

To mount secret as envs, add / uncomment follwing lines from deployment's manifest:

```yaml

  envFrom:
    - secretRef:
        name: example-secret

```

