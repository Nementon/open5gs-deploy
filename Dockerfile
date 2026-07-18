FROM ubuntu:22.04

# Avoid prompts during installation
ENV DEBIAN_FRONTEND=noninteractive

# Install common dependencies
RUN apt-get update && apt-get install -y \
    software-properties-common \
    gnupg \
    ca-certificates \
    curl \
    iproute2 \
    iptables \
    net-tools \
    iputils-ping \
    tcpdump \
    && rm -rf /var/lib/apt/lists/*

# Add Open5GS PPA and install Open5GS & WebUI
RUN add-apt-repository ppa:open5gs/latest \
    && apt-get update \
    && apt-get install -y open5gs open5gs-webui \
    && rm -rf /var/lib/apt/lists/*

# Set up runtime directories and logs link
RUN mkdir -p /open5gs/config /open5gs/logs /var/log/open5gs

# Copy entrypoint script
COPY entrypoint.sh /open5gs/entrypoint.sh
RUN chmod +x /open5gs/entrypoint.sh

# Set working directory
WORKDIR /open5gs

# Define entrypoint
ENTRYPOINT ["/open5gs/entrypoint.sh"]
