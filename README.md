
# Repository for generic cicd templates.

## Importing workflows

To import workflows, copy the [examples/workflows](./examples/workflows) directory to you repo .github dir on main branch.

While doing initial ci commits, include a [ci skip ] in commit message, to skip running the build-and-deploy workflow.

Workflows need following secrets to be set on repo level:

```yaml 
  DOCKER_USERNAME

  DOCKER_PASSWORD

  KUBE_CONFIG
```

Trigger conditions can be set per repo in workflow file 

[ How to set triggers ](https://docs.github.com/en/actions/writing-workflows/choosing-when-your-workflow-runs/events-that-trigger-workflows)


## Build and deploy 

   Runs either on push to main branch, or on manual trigger.

   Steps:

    - extract version from package.json
    - if a docker image tagged with this version hasn't been pushed to registry, build it
    - if a git tag with this version doesn't exist, tag the commit 
    - deploy k8s manifests, using version read from package.json


   If there was a change in version, but not in manifests - job will build and run a new version.

   If there was no change in version, but there was a change in manifest - job will run new manifests with the latest version.

   If there was no changes in manifests, nor in version, job will do nothing.

## Deploy

  Runs on manual trigger and requires a docker image tag to run.

  Deploys given image to k8s


## Importing K8s templates

To enable k8s deploy, copy the [examples/k8s](./examples/k8s) directory to you repo root dir.

[cicd-inputs](./examples/k8s/cicd-inputs.yaml) file specifies variables to be passed to following pipelines and has to be set.


todo toggle ingress deployment

