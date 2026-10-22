# ============================================
# ScopeFinder 2.0 - Enhanced Dockerfile
# ============================================
# Multi-architecture support for amd64 and arm64
# Optimized for size and build speed
# ============================================

# Use slim base for smaller image.
# Pinned by digest for reproducible builds / supply-chain integrity.
# Bump deliberately: docker buildx imagetools inspect debian:bookworm-slim
FROM debian:bookworm-slim@sha256:7ff6ba31527b9e336162fa061746c366c4b2032f4d2cff2078bea43f78efe3f8

# Build arguments for multi-architecture support
ARG TARGETPLATFORM
ARG TARGETARCH
ARG TARGETVARIANT

# Environment variables
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=UTC

# ============================================
# LAYER 1: Essential build tools
# ============================================
RUN apt-get update && apt-get install -y --no-install-recommends \
    apt-utils \
    ca-certificates \
    curl \
    wget \
    git \
    make \
    gcc \
    g++ \
    build-essential \
    pkg-config \
    unzip \
    xdg-utils \
    && rm -rf /var/lib/apt/lists/*

# ============================================
# LAYER 2: Language runtimes and utilities
# ============================================
RUN apt-get update && apt-get install -y --no-install-recommends \
    ruby \
    ruby-dev \
    python3 \
    python3-pip \
    pipx \
    jq \
    dnsutils \
    && rm -rf /var/lib/apt/lists/*

# ============================================
# LAYER 3: Chrome/Chromium dependencies
# ============================================
RUN apt-get update && apt-get install -y --no-install-recommends \
    libnss3 \
    libxss1 \
    libatk1.0-0 \
    libatk-bridge2.0-0 \
    libdrm2 \
    libx11-xcb1 \
    libxcomposite1 \
    libxcursor1 \
    libxdamage1 \
    libxi6 \
    libxtst6 \
    libasound2 \
    libpangocairo-1.0-0 \
    libpango1.0-0 \
    libcups2 \
    libxkbcommon0 \
    fonts-liberation \
    libgbm-dev \
    libxrandr2 \
    libjpeg-dev \
    && rm -rf /var/lib/apt/lists/*

# ============================================
# LAYER 4: Development libraries
# ============================================
RUN apt-get update && apt-get install -y --no-install-recommends \
    libssl-dev \
    libcurl4-openssl-dev \
    libxml2 \
    libxml2-dev \
    libxslt1-dev \
    libgmp-dev \
    zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# ============================================
# Install Golang with multi-arch support
# ============================================
# Pinned Go toolchain + per-arch tarball checksum verification.
# Bump: pick a version from https://go.dev/dl/?mode=json and update the sha256s.
ARG GO_VERSION=1.27.3
ARG GO_SHA256_AMD64=65efbc80fdc1fa2cd2631cad5b481777a68e8725f34e89f50fc6ac714e379b40
ARG GO_SHA256_ARM64=a06e99309dbcbdca1a8ccd2282c3ee146e55930886e26b4f1193269587165f49
RUN set -ex && \
    if [ -z "${TARGETARCH}" ]; then \
        TARGETARCH="$(dpkg --print-architecture)"; \
    fi && \
    case "${TARGETARCH}" in \
        amd64) GO_TARBALL="go${GO_VERSION}.linux-amd64.tar.gz"; GO_SHA256="${GO_SHA256_AMD64}" ;; \
        arm64) GO_TARBALL="go${GO_VERSION}.linux-arm64.tar.gz"; GO_SHA256="${GO_SHA256_ARM64}" ;; \
        *) echo "Unsupported architecture: ${TARGETARCH}" && exit 1 ;; \
    esac && \
    wget -q "https://go.dev/dl/${GO_TARBALL}" && \
    echo "${GO_SHA256}  ${GO_TARBALL}" | sha256sum -c - && \
    tar -C /usr/local -xzf "${GO_TARBALL}" && \
    rm "${GO_TARBALL}" && \
    /usr/local/go/bin/go version

# ============================================
# Install Rust
# ============================================
# NOTE: rustup toolchain floats on "stable". x8 below is version-pinned; we do
# NOT pass --locked because x8's shipped Cargo.lock pins an ancient `time` crate
# that fails to compile on current rustc. Cargo still verifies registry checksums
# for every resolved dep. Pin a toolchain here for fully reproducible Rust builds.
RUN curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable

# ============================================
# Install Chromium with multi-arch support
# ============================================
RUN set -ex && \
    # Detect architecture if not set
    if [ -z "${TARGETARCH}" ]; then \
        TARGETARCH="$(dpkg --print-architecture)"; \
    fi && \
    case "${TARGETARCH}" in \
        amd64) \
            CHROMIUM_VERSION="1131003" && \
            CHROMIUM_URL="https://storage.googleapis.com/chromium-browser-snapshots/Linux_x64/${CHROMIUM_VERSION}/chrome-linux.zip" \
            ;; \
        arm64) \
            CHROMIUM_VERSION="270195" && \
            CHROMIUM_URL="https://storage.googleapis.com/chromium-browser-snapshots/Linux_ARM_Cross-Compile/${CHROMIUM_VERSION}/chrome-linux.zip" \
            ;; \
        *) \
            echo "Unsupported architecture: ${TARGETARCH}" && exit 1 \
            ;; \
    esac && \
    wget -q "${CHROMIUM_URL}" && \
    mkdir -p /root/.cache/rod/browser/chromium-${CHROMIUM_VERSION} && \
    unzip -q chrome-linux.zip && \
    mv chrome-linux/* /root/.cache/rod/browser/chromium-${CHROMIUM_VERSION}/ && \
    rm -rf chrome-linux.zip chrome-linux && \
    echo "Chromium ${CHROMIUM_VERSION} installed for ${TARGETARCH}"

# ============================================
# Install TruffleHog with multi-arch support
# ============================================
ARG TRUFFLEHOG_VERSION=3.94.2
# Per-arch release checksums (from trufflehog_${VERSION}_checksums.txt).
ARG TRUFFLEHOG_SHA256_AMD64=6ff6854f7f663c208c23a3d9be37d2333d15857c28cbe7f008a7fc910a88768d
ARG TRUFFLEHOG_SHA256_ARM64=63cdfa87a7f0678774d485574cabacb72ecfc306b4be96f0aafcb41f08de3514
RUN set -ex && \
    # Detect architecture if not set
    if [ -z "${TARGETARCH}" ]; then \
        TARGETARCH="$(dpkg --print-architecture)"; \
    fi && \
    case "${TARGETARCH}" in \
        amd64) FILENAME="trufflehog_${TRUFFLEHOG_VERSION}_linux_amd64.tar.gz"; TH_SHA256="${TRUFFLEHOG_SHA256_AMD64}" ;; \
        arm64) FILENAME="trufflehog_${TRUFFLEHOG_VERSION}_linux_arm64.tar.gz"; TH_SHA256="${TRUFFLEHOG_SHA256_ARM64}" ;; \
        *) echo "Unsupported architecture: ${TARGETARCH}" && exit 1 ;; \
    esac && \
    wget -q "https://github.com/trufflesecurity/trufflehog/releases/download/v${TRUFFLEHOG_VERSION}/${FILENAME}" && \
    echo "${TH_SHA256}  ${FILENAME}" | sha256sum -c - && \
    tar -xzf "${FILENAME}" && \
    mv trufflehog /usr/local/bin/ && \
    chmod +x /usr/local/bin/trufflehog && \
    rm "${FILENAME}" && \
    trufflehog --version

# ============================================
# Install public Go tools (pinned: semver tag where available, else commit SHA
# for untagged tools like sourcemapper/jsluice). Bump via Renovate (renovate.json).
# ============================================
RUN set -ex && \
    export PATH="/usr/local/go/bin:$PATH" && \
    export GOBIN="/root/go/bin" && \
    go install -v github.com/projectdiscovery/subfinder/v2/cmd/subfinder@v2.17.0 && \
    go install -v github.com/projectdiscovery/httpx/cmd/httpx@v1.12.0 && \
    go install -v github.com/s0md3v/smap/cmd/smap@v1.0.0-beta && \
    go install -v github.com/incogbyte/shosubgo@ccb6dc7bf0ef130fef0a6948acfec1235b26d81f && \
    go install -v github.com/g0ldencybersec/CloudRecon@8893d40372cee7b55e2b20073283c7bb812f2a25 && \
    go install -v github.com/projectdiscovery/asnmap/cmd/asnmap@v1.1.1 && \
    go install -v github.com/denandz/sourcemapper@f739bd5dd266b0d0e2cfa17c0a132f79bd9a5ba9 && \
    go install -v github.com/projectdiscovery/nuclei/v3/cmd/nuclei@v3.11.1 && \
    go install -v github.com/BishopFox/jsluice/cmd/jsluice@0ddfab153e060a9eeaded4d8669233f7c071e7e4 && \
    echo "Public Go tools installed"

# ============================================
# Bake nuclei templates into the image (faster runtime updates)
# ============================================
# SUPPLY-CHAIN NOTE: the nuclei binary is pinned above, but its detection
# templates are the one intentionally-fresh component — they are ProjectDiscovery
# -maintained YAML rules, fetched here at build time and refreshed at runtime by
# the subdomain_takeover module. To lock templates too, replace the command below
# with a pinned clone (git clone --depth 1 -b vX.Y.Z nuclei-templates into nuclei's
# templates dir) and gate the runtime `nuclei -update-templates` in that module.
RUN set -ex && \
    export PATH="/root/go/bin:$PATH" && \
    nuclei -update-templates && \
    echo "Nuclei templates installed"

# ============================================
# Install katana from 0xQRx fork (adds -ss scroll simulation)
# ============================================
# Pinned to a specific commit on the fork's dev branch (not a moving branch tip).
ARG KATANA_COMMIT=55f1ac9dbda4d42321811d837b77d3fb11c9aacf
RUN set -ex && \
    export PATH="/usr/local/go/bin:$PATH" && \
    export GOBIN="/root/go/bin" && \
    git clone https://github.com/0xQRx/katana.git /tmp/katana && \
    cd /tmp/katana && \
    git checkout "${KATANA_COMMIT}" && \
    CGO_ENABLED=1 go build -o "${GOBIN}/katana" ./cmd/katana/ && \
    rm -rf /tmp/katana && \
    echo "Katana (0xQRx fork @ ${KATANA_COMMIT}) installed"

# ============================================
# Install private Go tools (with GOPRIVATE)
# ============================================
RUN set -ex && \
    export PATH="/usr/local/go/bin:$PATH" && \
    export GOBIN="/root/go/bin" && \
    GOPRIVATE=github.com/0xQRx go install -v github.com/0xQRx/crtsh-tool/cmd/crtsh-tool@edf1f50b8fe95a4933576e0377168aeaee94a779 && \
    GOPRIVATE=github.com/0xQRx go install -v github.com/0xQRx/jshunter@1808b250f70765e527868f09ea9da2d63551e881 && \
    GOPRIVATE=github.com/0xQRx go install -v github.com/0xQRx/godigger@09387d4afa9df874bb9ef89431be967353bed2a0 && \
    GOPRIVATE=github.com/0xQRx go install -v github.com/0xQRx/URLDedup/cmd/urldedup@3a9a20bb1b735aa5ac0b7f81c9cf5c540e0cd4ca && \
    echo "Private Go tools installed"

# ============================================
# Install Python tools
# ============================================
RUN set -ex && \
    export PATH="/root/.local/bin:$PATH" && \
    pipx install "git+https://github.com/xnl-h4ck3r/waymore.git@v8.9" && \
    pipx install "git+https://github.com/0xQRx/LinkFinder.git@194431c6b2e53cea9598c2bae22fe0cd2a0a18a4" --include-deps && \
    pipx install "git+https://github.com/xnl-h4ck3r/xnLinkFinder.git@v8.2" && \
    pipx install "git+https://github.com/0xQRx/msftrecon.git@fd6d66304eb0166e80ad875b98e3fd113d446c62" && \
    pipx install "uro==1.0.2" && \
    pipx install "git+https://github.com/0xQRx/graphql-cop.git@ed61858ef12b555a887dd194cc6b6ff4b79e10ec" && \
    echo "Python tools installed"

# ============================================
# Install Ruby tools
# ============================================
# 3.8.28 is the newest wpscan supporting the base image's Ruby (3.1); 4.x needs
# Ruby >= 3.3. Bump in lockstep with a Ruby upgrade.
RUN gem install wpscan -v 3.8.28 && \
    wpscan --version && \
    echo "Ruby tools installed"

# ============================================
# Install Rust tools
# ============================================
RUN set -ex && \
    export PATH="/root/.cargo/bin:$PATH" && \
    cargo install x8 --version 4.3.2 && \
    echo "Rust tools installed"

# ============================================
# Download wordlists
# ============================================
RUN mkdir -p /wordlists && \
    cd /wordlists && \
    wget -q https://raw.githubusercontent.com/danielmiessler/SecLists/2026.1/Discovery/Web-Content/burp-parameter-names.txt && \
    echo "Wordlists downloaded"

# ============================================
# Set up final environment variables and PATH
# ============================================
ENV PATH="/usr/local/go/bin:/root/go/bin:/root/.cargo/bin:/root/.local/bin:$PATH" \
    GOBIN="/root/go/bin" \
    GO111MODULE=on \
    GOPROXY=https://proxy.golang.org,direct \
    GOPRIVATE=github.com/0xQRx

# ============================================
# Verify all tools are installed
# ============================================
RUN set -ex && \
    echo "=== Verifying tool installation ===" && \
    subfinder -version 2>/dev/null | head -1 && \
    httpx -version 2>/dev/null | head -1 && \
    katana -version 2>/dev/null | head -1 && \
    asnmap -version 2>/dev/null | head -1 && \
    sourcemapper -version 2>/dev/null | head -1 && \
    nuclei -version 2>/dev/null | head -1 && \
    smap -h 2>&1 | head -1 && \
    which crtsh-tool && \
    which jshunter && \
    which godigger && \
    which urldedup && \
    which waymore && \
    which linkfinder && \
    which xnLinkFinder && \
    which msftrecon && \
    which uro && \
    which shosubgo && \
    which CloudRecon && \
    which jsluice && \
    wpscan --version | head -1 && \
    x8 --version && \
    trufflehog --version && \
    echo "=== All tools verified successfully ==="

# ============================================
# Create output directory
# ============================================
RUN mkdir -p /output

# ============================================
# Set working directory
# ============================================
WORKDIR /output

# ============================================
# Set environment for ScopeFinder
# ============================================
ENV SCRIPT_DIR=/opt \
    DISABLE_UPDATE_CHECK=true \
    GOGC=50

# ============================================
# Metadata labels
# ============================================
LABEL maintainer="ScopeFinder" \
      version="2.0" \
      description="ScopeFinder 2.0 - Modular reconnaissance framework" \
      architecture="${TARGETARCH}"

# ============================================
# Health check
# ============================================
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD subfinder -version && httpx -version && echo "Health check passed" || exit 1

# ============================================
# Entry point - default to bash, will be overridden when mounting scripts
# ============================================
ENTRYPOINT ["/bin/bash"]