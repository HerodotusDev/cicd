# CI/CD Deployment Guide for Developers

This guide explains how to use this repository to deploy your applications using GitHub Actions workflows.

## Prerequisites

Before you start, ensure you have:
1. A GitHub repository for your application
2. Docker Hub account (for container images)
3. Kubernetes cluster access
4. etcd access (if using configuration management)

## Quick Start

1. **Add the workflow to your repository**
   - Copy the workflow from `examples/workflows/build-and-deploy-workflow.yaml`
   - Place it in your repository at `.github/workflows/deploy.yaml`
   - Update the `inputs_file` path to point to your configuration

2. **Create your deployment configuration**
   - Use `examples/k8s/cicd-inputs.yaml` as a template
   - Update the values for your application:
     - `namespace`
     - `app_names`
     - `dockerhub_project`

3. **Create Kubernetes manifests**
   - Use `examples/k8s/deployment.yaml` as a template for your deployment
   - Use `examples/k8s/ingress.yaml` as a template for your ingress
   - Place them in your repository's `k8s/` directory

## Configuration Guide

### 1. Input Configuration

The `cicd-inputs.yaml` file controls your deployment configuration. See `examples/k8s/cicd-inputs.yaml` for a complete example with all available options.

Key configurations:
- `namespace`: Your Kubernetes namespace
- `app_names`: Comma-separated list of apps to deploy
- `dockerhub_project`: Your Docker Hub project name

Optional configurations:
- `deployment_file`: Custom deployment file path
- `ingress_file`: Custom ingress file path
- `rollout_timeout`: Deployment timeout in seconds
- `pull_etcd_config`: Enable etcd config pulling
- `etcd_key`: etcd configuration key

### 2. Kubernetes Manifests

1. **Deployment Manifest**
   - Template: `examples/k8s/deployment.yaml`
   - Place in: `k8s/deployment.yaml`
   - Update the container image and other specifications

2. **Ingress Manifest**
   - Template: `examples/k8s/ingress.yaml`
   - Place in: `k8s/ingress.yaml`
   - Configure your domain and routing rules

### 3. Docker Configuration

1. Create a `Dockerfile` for your application
2. Name it `Dockerfile.${{ app_name }}` for each app
3. Place it in your repository's root directory

## Workflow Features

The CI/CD workflow provides:

1. **Automatic Versioning**
   - Reads version from `package.json`
   - Creates Git tags for releases

2. **Container Building**
   - Builds Docker images
   - Pushes to Docker Hub
   - Tags images with version

3. **Kubernetes Deployment**
   - Deploys to specified namespace
   - Configures ingress
   - Handles rollout with timeout

4. **Configuration Management**
   - Optional etcd integration
   - Pulls configuration from etcd
   - Updates secrets if needed

## Environment Variables

The workflow requires these environment variables:

```bash
ARC_DOCKER_USERNAME=your-docker-username
ARC_DOCKER_PASSWORD=your-docker-password
ARC_ETCD_USER=your-etcd-username      # If using etcd
ARC_ETCD_PASSWORD=your-etcd-password  # If using etcd
```

## Troubleshooting

1. **Deployment Fails**
   - Check Kubernetes manifests
   - Verify namespace exists
   - Check image pull permissions

2. **Build Fails**
   - Verify Dockerfile
   - Check Docker Hub credentials
   - Ensure proper file naming

3. **Configuration Issues**
   - Verify etcd connection
   - Check configuration keys
   - Validate input file format

## Support

For issues and support:
1. Check existing issues
2. Create a new issue
3. Contact the maintainers

## Best Practices

1. **Version Control**
   - Keep manifests in version control
   - Use meaningful commit messages
   - Tag releases appropriately

2. **Security**
   - Use secrets for credentials
   - Limit namespace access
   - Regular security audits

3. **Monitoring**
   - Set up proper logging
   - Configure alerts
   - Monitor deployment health 