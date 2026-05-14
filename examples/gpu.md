# GPU Workloads

## Deployment

Add these fields to your deployment spec:

```yaml
spec:
  template:
    spec:
      runtimeClassName: nvidia
      tolerations:
        - key: kind
          value: gpu-worker
          effect: NoSchedule
      containers:
        - name: my-app
          image: <IMAGE>
          resources:
            limits:
              nvidia.com/gpu: "1"
```

- `runtimeClassName: nvidia` — routes the pod through the NVIDIA container runtime, which injects GPU devices (`/dev/nvidia*`) and driver libraries (`nvidia-smi`, CUDA, etc.) into the container automatically.
- `tolerations` — required because GPU nodes have a `kind=gpu-worker:NoSchedule` taint. Without this, the pod won't schedule on GPU nodes.
- `nvidia.com/gpu: "1"` — requests one GPU. The scheduler places the pod on a node that has a free GPU. Only set this under `limits`; do not set it under `requests` separately.

### Full example (based on app-deployment.yaml)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: example-gpu
spec:
  replicas: 1
  selector:
    matchLabels:
      app: example-gpu
  template:
    metadata:
      labels:
        app: example-gpu
    spec:
      runtimeClassName: nvidia
      imagePullSecrets:
        - name: dockerhub-secret
      tolerations:
        - key: kind
          value: gpu-worker
          effect: NoSchedule
      containers:
        - name: example-gpu
          image: <IMAGE>
          resources:
            limits:
              nvidia.com/gpu: "1"
              cpu: "2"
              memory: "8Gi"
          ports:
            - containerPort: 8040
```

## Dockerfile

Base your image on an NVIDIA CUDA base image. Do **not** install NVIDIA drivers — they are injected at runtime by the `nvidia` RuntimeClass.

Pick a base image tier:

| Tier | Image | Use when |
|------|-------|----------|
| base | `nvidia/cuda:12.4.1-base-ubuntu22.04` | You only need the CUDA runtime (smallest) |
| runtime | `nvidia/cuda:12.4.1-runtime-ubuntu22.04` | You need cuDNN / cuBLAS at runtime |
| devel | `nvidia/cuda:12.4.1-devel-ubuntu22.04` | You need `nvcc` to compile CUDA code at build time |

### Example Dockerfile (Python + PyTorch)

```dockerfile
FROM nvidia/cuda:12.4.1-runtime-ubuntu22.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-pip && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip3 install --no-cache-dir -r requirements.txt

COPY . .
CMD ["python3", "main.py"]
```

### Example Dockerfile (Node.js calling a GPU binary)

```dockerfile
FROM nvidia/cuda:12.4.1-base-ubuntu22.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl && \
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY package*.json ./
RUN npm ci --production

COPY . .
CMD ["node", "index.js"]
```

### Key rules

1. **Never install NVIDIA drivers in the image.** The host drivers are mounted into the container at runtime.
2. **Match the CUDA version** in your base image to the libraries your app needs (PyTorch, TensorFlow, etc. each specify a supported CUDA version).
3. **`nvidia-smi` is available at runtime** inside the container — you don't need to install it.
4. **Test locally** with `docker run --gpus all your-image` if you have a local GPU, or just deploy to the cluster.
