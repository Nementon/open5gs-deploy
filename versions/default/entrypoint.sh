#!/bin/bash
set -e

# Enable IP forwarding inside the container
sysctl -w net.ipv4.ip_forward=1 || true

NF=$1
shift || true

# Helper function to print usage
usage() {
    echo "Usage: $0 [amf|smf|upf|nrf|udr|udm|ausf|pcf|nssf|bsf|webui]"
    exit 1
}

if [ -z "$NF" ]; then
    usage
fi

# Helper function to resolve a service name using DNS with retries
resolve_ip() {
    local host=$1
    local ip=""
    for i in {1..30}; do
        # Use getent hosts to resolve IP. 
        # Inside docker network, service names resolve directly.
        ip=$(getent hosts "$host" | awk '{print $1}' | head -n1)
        if [ -n "$ip" ]; then
            echo "$ip"
            return 0
        fi
        sleep 1
    done
    echo "ERROR: Failed to resolve host: $host" >&2
    exit 1
}

# Dynamic Configuration Processing (except for WebUI which has no YAML config)
if [ "$NF" != "webui" ]; then
    # Get local container IP address on eth0
    MY_IP=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
    echo "Local container IP: ${MY_IP}"

    # Create writable tmp config directory and copy config template
    mkdir -p /tmp/config
    cp /open5gs/config/${NF}.yaml /tmp/config/${NF}.yaml

    # Replace MY_IP placeholder
    sed -i "s/{{MY_IP}}/${MY_IP}/g" /tmp/config/${NF}.yaml

    # Resolve NRF IP for components that require registration
    if [ "$NF" != "nrf" ] && [ "$NF" != "upf" ]; then
        echo "Waiting for NRF to be resolvable..."
        NRF_IP=$(resolve_ip nrf)
        echo "Resolved NRF IP: ${NRF_IP}"
        sed -i "s/{{NRF_IP}}/${NRF_IP}/g" /tmp/config/${NF}.yaml
    fi

    # Resolve UPF IP for SMF (needed for SMF client association config)
    if [ "$NF" = "smf" ]; then
        echo "Waiting for UPF to be resolvable..."
        UPF_IP=$(resolve_ip upf)
        echo "Resolved UPF IP: ${UPF_IP}"
        sed -i "s/{{UPF_IP}}/${UPF_IP}/g" /tmp/config/${NF}.yaml
    fi
fi

case "$NF" in
    amf)
        echo "Starting AMF..."
        exec open5gs-amfd -c /tmp/config/amf.yaml "$@"
        ;;
    smf)
        echo "Starting SMF..."
        exec open5gs-smfd -c /tmp/config/smf.yaml "$@"
        ;;
    upf)
        echo "Configuring UPF Network (TUN & NAT)..."
        # Ensure /dev/net/tun is available
        if [ ! -c /dev/net/tun ]; then
            mkdir -p /dev/net
            mknod /dev/net/tun c 10 200
            chmod 600 /dev/net/tun
        fi

        # Delete existing TUN if present
        ip link delete ogstun dev ogstun 2>/dev/null || true

        # Create TUN interface
        ip tuntap add name ogstun mode tun
        ip addr add ${UE_GATEWAY:-10.45.0.1/16} dev ogstun
        ip link set ogstun up

        # Set up NAT/MASQUERADE to route UE traffic to the outer network
        iptables -t nat -A POSTROUTING -s ${UE_SUBNET:-10.45.0.0/16} ! -o ogstun -j MASQUERADE

        echo "Starting UPF..."
        exec open5gs-upfd -c /tmp/config/upf.yaml "$@"
        ;;
    nrf)
        echo "Starting NRF..."
        exec open5gs-nrfd -c /tmp/config/nrf.yaml "$@"
        ;;
    udr)
        echo "Starting UDR..."
        exec open5gs-udrd -c /tmp/config/udr.yaml "$@"
        ;;
    udm)
        echo "Starting UDM..."
        exec open5gs-udmd -c /tmp/config/udm.yaml "$@"
        ;;
    ausf)
        echo "Starting AUSF..."
        exec open5gs-ausfd -c /tmp/config/ausf.yaml "$@"
        ;;
    pcf)
        echo "Starting PCF..."
        exec open5gs-pcfd -c /tmp/config/pcf.yaml "$@"
        ;;
    nssf)
        echo "Starting NSSF..."
        exec open5gs-nssfd -c /tmp/config/nssf.yaml "$@"
        ;;
    bsf)
        echo "Starting BSF..."
        exec open5gs-bsfd -c /tmp/config/bsf.yaml "$@"
        ;;
    webui)
        echo "Starting WebUI..."
        cd /opt/open5gs/webui
        exec /usr/bin/node server/index.js "$@"
        ;;
    *)
        echo "Unknown Network Function: $NF"
        usage
        ;;
esac
