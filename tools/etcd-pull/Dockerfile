# Use an official minimal Linux image
FROM alpine:3.17

# Install required dependencies (etcdctl, bash, coreutils)
RUN apk add --no-cache bash curl tar coreutils

# Install etcdctl
ARG ETCD_VERSION=v3.5.5
RUN curl -L https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-linux-amd64.tar.gz \
    -o etcd.tar.gz && \
    tar xzvf etcd.tar.gz && \
    mv etcd-${ETCD_VERSION}-linux-amd64/etcdctl /usr/local/bin/ && \
    rm -rf etcd.tar.gz etcd-${ETCD_VERSION}-linux-amd64

# Set working directory
WORKDIR /app

# Copy the secret generation script
COPY pull-config.sh /app/pull-config.sh

# Make sure the script is executable
RUN chmod +x /app/pull-config.sh

# Set entrypoint to run the script
ENTRYPOINT ["/app/pull-config.sh"]