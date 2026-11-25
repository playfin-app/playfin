FROM ubuntu:24.04

ARG TARGETARCH
ARG WEBOS_SDK_TAG=2026.08-webos

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    clang \
    curl \
    file \
    git \
    build-essential \
    libclang-dev \
    nodejs \
    npm \
    xz-utils \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g @webos-tools/cli

# Rust toolchain + armv7 softfp target matching openlgtv/buildroot-nc4
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:${PATH}

RUN curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs \
    | sh -s -- -y --default-toolchain stable --profile minimal \
    && rustup target add armv7-unknown-linux-gnueabi

# Install openlgtv/buildroot-nc4 SDK matching Docker host architecture (amd64 or arm64)
RUN SDK_ARCH=$([ "$TARGETARCH" = "arm64" ] && echo "aarch64" || echo "x86_64") \
    && mkdir -p /opt/webos-sdk \
    && curl -fsSL --retry 3 -o /tmp/webos-sdk.tar.gz \
       "https://github.com/openlgtv/buildroot-nc4/releases/download/${WEBOS_SDK_TAG}/arm-webos-linux-gnueabi_sdk-buildroot-${SDK_ARCH}.tar.gz" \
    && tar -xzf /tmp/webos-sdk.tar.gz --strip-components=1 -C /opt/webos-sdk \
    && rm -f /tmp/webos-sdk.tar.gz \
    && cd /opt/webos-sdk && ./relocate-sdk.sh

ENV WEBOS_SDK=/opt/webos-sdk
WORKDIR /workspace
