# Use an official minimal Linux image
FROM alpine:3.17

# Install required dependencies (etcdctl, bash, coreutils)
RUN apk add --no-cache bash curl tar coreutils

# Install etcdctl (multi-arch: TARGETARCH is set by buildx per platform;
# amd64/arm64 are the arches the CI runners and the home cluster use).
ARG ETCD_VERSION=v3.5.5
ARG TARGETARCH
RUN case "${TARGETARCH}" in \
      amd64) ETCD_ARCH=amd64 ;; \
      arm64) ETCD_ARCH=arm64 ;; \
      *) echo "unsupported TARGETARCH '${TARGETARCH}'" >&2; exit 1 ;; \
    esac \
    && curl -L "https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-linux-${ETCD_ARCH}.tar.gz" \
    -o etcd.tar.gz && \
    tar xzvf etcd.tar.gz && \
    mv "etcd-${ETCD_VERSION}-linux-${ETCD_ARCH}/etcdctl" /usr/local/bin/ && \
    rm -rf "etcd.tar.gz" "etcd-${ETCD_VERSION}-linux-${ETCD_ARCH}"

# Set working directory
WORKDIR /app

# Copy the secret generation script
COPY pull-config.sh /app/pull-config.sh

# Make sure the script is executable
RUN chmod +x /app/pull-config.sh

# Set entrypoint to run the script
ENTRYPOINT ["/app/pull-config.sh"]