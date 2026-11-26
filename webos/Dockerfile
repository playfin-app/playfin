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
    && npm install -g @webos-tools/cli@3.2.6

# Rust toolchain + armv7 softfp target matching openlgtv/buildroot-nc4
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:${PATH}

RUN curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs \
    | sh -s -- -y --default-toolchain stable --profile minimal \
    && rustup target add armv7-unknown-linux-gnueabi

# Install openlgtv/buildroot-nc4 SDK matching Docker host architecture (amd64 or arm64) and verify SHA256
RUN if [ "$TARGETARCH" = "arm64" ]; then \
        SDK_ARCH="aarch64"; \
        SDK_SHA256="3a9330f3789f8008ece7c8a48f58c3a71d0307a9a1f81896db938b785524c3ce"; \
    else \
        SDK_ARCH="x86_64"; \
        SDK_SHA256="2230a6351e5cce6fcb9d4fdcb4697335f223995401ef969c81744aaeb14c5344"; \
    fi \
    && mkdir -p /opt/webos-sdk \
    && curl -fsSL --retry 3 -o /tmp/webos-sdk.tar.gz \
       "https://github.com/openlgtv/buildroot-nc4/releases/download/${WEBOS_SDK_TAG}/arm-webos-linux-gnueabi_sdk-buildroot-${SDK_ARCH}.tar.gz" \
    && echo "${SDK_SHA256}  /tmp/webos-sdk.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/webos-sdk.tar.gz --strip-components=1 -C /opt/webos-sdk \
    && rm -f /tmp/webos-sdk.tar.gz \
    && cd /opt/webos-sdk && ./relocate-sdk.sh

ENV WEBOS_SDK=/opt/webos-sdk
WORKDIR /workspace
