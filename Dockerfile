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
    curl \
    && curl -fsSL https://deb.nodesource.com/setup_18.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Copy compiled binaries and libraries from builder
COPY --from=builder /opt/open5gs /opt/open5gs

# Copy the built WebUI folder from builder
COPY --from=builder /src/open5gs/webui /opt/open5gs/webui

# Configure search paths for binaries and shared libraries
ENV PATH="/opt/open5gs/bin:${PATH}"
ENV LD_LIBRARY_PATH="/opt/open5gs/lib:/opt/open5gs/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH}"

# Set up runtime directories and logs
RUN mkdir -p /open5gs/config /open5gs/logs /var/log/open5gs

# Copy entrypoint script (from host context)
COPY entrypoint.sh /open5gs/entrypoint.sh
RUN chmod +x /open5gs/entrypoint.sh

# Set working directory
WORKDIR /open5gs

# Define entrypoint
ENTRYPOINT ["/open5gs/entrypoint.sh"]
