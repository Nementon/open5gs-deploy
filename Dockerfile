# ==========================================
# Stage 1: Build Environment
# ==========================================
FROM ubuntu:22.04 AS builder

ARG OPEN5GS_VERSION=v2.7.2

# Avoid prompts during installation
ENV DEBIAN_FRONTEND=noninteractive

# Install compilation dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3-pip \
    python3-setuptools \
    python3-wheel \
    ninja-build \
    build-essential \
    flex \
    bison \
    git \
    cmake \
    libsctp-dev \
    libgnutls28-dev \
    libgcrypt-dev \
    libssl-dev \
    libmongoc-dev \
    libbson-dev \
    libyaml-dev \
    libnghttp2-dev \
    libmicrohttpd-dev \
    libcurl4-gnutls-dev \
    libtins-dev \
    libtalloc-dev \
    meson \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install specific libidn package depending on OS availability
RUN apt-get update && (apt-get install -y --no-install-recommends libidn-dev || apt-get install -y --no-install-recommends libidn11-dev) && rm -rf /var/lib/apt/lists/*

# Clone the specified Open5GS repository tag (including submodules)
WORKDIR /src
RUN git clone --recursive --branch ${OPEN5GS_VERSION} https://github.com/open5gs/open5gs.git

# Build and install Open5GS C binaries
WORKDIR /src/open5gs
RUN meson build --prefix=/opt/open5gs && \
    ninja -C build install

# Install Node.js and NPM to build the WebUI production dependencies
RUN apt-get update && apt-get install -y --no-install-recommends nodejs npm && rm -rf /var/lib/apt/lists/*
WORKDIR /src/open5gs/webui
RUN npm install --only=production

# ==========================================
# Stage 2: Runtime Environment
# ==========================================
FROM ubuntu:22.04

# Avoid prompts during installation
ENV DEBIAN_FRONTEND=noninteractive

# Install runtime dependencies only (optimized size)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libsctp1 \
    libgnutls30 \
    libgcrypt20 \
    libssl3 \
    libmongoc-1.0-0 \
    libbson-1.0-0 \
    libyaml-0-2 \
    libnghttp2-14 \
    libmicrohttpd12 \
    libcurl3-gnutls \
    libtins4.0 \
    libtalloc2 \
    libidn12 \
    iproute2 \
    iptables \
    net-tools \
    iputils-ping \
    tcpdump \
    ca-certificates \
    ethtool \
    curl \
    && curl -fsSL https://deb.nodesource.com/setup_18.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Copy compiled binaries and libraries from builder
COPY --from=builder /opt/open5gs /opt/open5gs

# Copy the built WebUI folder from builder
COPY --from=builder /src/open5gs/webui /opt/open5gs/webui

# Create unprivileged system group and user open5gs with explicit reserved high UID/GID (9999)
RUN groupadd -g 9999 open5gs && useradd -u 9999 -g 9999 -s /bin/false -M open5gs

# Configure search paths for binaries and shared libraries
ENV PATH="/opt/open5gs/bin:${PATH}"
ENV LD_LIBRARY_PATH="/opt/open5gs/lib:/opt/open5gs/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH}"

# Argument to identify Open5GS target version (matching builder stage)
ARG OPEN5GS_VERSION=v2.7.2

# Copy the entire versions folder to a temporary context
COPY versions /tmp/versions

# Resolve and copy version-specific or default configuration, entrypoint, and provision script
RUN mkdir -p /open5gs/config /open5gs/logs /var/log/open5gs /tmp/config && \
    if [ -d "/tmp/versions/${OPEN5GS_VERSION}" ]; then \
        echo "Using specific configurations for version ${OPEN5GS_VERSION}"; \
        cp -aL /tmp/versions/${OPEN5GS_VERSION}/config/* /open5gs/config/ 2>/dev/null || cp -a /tmp/versions/default/config/* /open5gs/config/; \
        cp -L /tmp/versions/${OPEN5GS_VERSION}/entrypoint.sh /open5gs/entrypoint.sh 2>/dev/null || cp /tmp/versions/default/entrypoint.sh /open5gs/entrypoint.sh; \
        cp -L /tmp/versions/${OPEN5GS_VERSION}/provision.js /open5gs/provision.js 2>/dev/null || cp /tmp/versions/default/provision.js /open5gs/provision.js; \
    else \
        echo "Version ${OPEN5GS_VERSION} configs not found. Falling back to default configs."; \
        cp -a /tmp/versions/default/config/* /open5gs/config/; \
        cp /tmp/versions/default/entrypoint.sh /open5gs/entrypoint.sh; \
        cp /tmp/versions/default/provision.js /open5gs/provision.js; \
    fi && \
    chmod +x /open5gs/entrypoint.sh && \
    chown -R open5gs:open5gs /open5gs /opt/open5gs /var/log/open5gs /tmp/config && \
    chmod 755 /tmp/config && \
    rm -rf /tmp/versions

# Set working directory
WORKDIR /open5gs

# Define entrypoint
ENTRYPOINT ["/open5gs/entrypoint.sh"]
