#!/bin/bash
set -e

# Dynamically adjust open5gs UID and GID if custom values are passed via environment
if [ "$(id -u)" = "0" ]; then
    TARGET_UID="${OPEN5GS_UID:-9999}"
    TARGET_GID="${OPEN5GS_GID:-9999}"

    CURRENT_UID=$(id -u open5gs 2>/dev/null || echo "")
    CURRENT_GID=$(id -g open5gs 2>/dev/null || echo "")

    if [ -n "$TARGET_GID" ] && [ "$TARGET_GID" != "$CURRENT_GID" ]; then
        groupmod -o -g "$TARGET_GID" open5gs 2>/dev/null || true
    fi
    if [ -n "$TARGET_UID" ] && [ "$TARGET_UID" != "$CURRENT_UID" ]; then
        usermod -o -u "$TARGET_UID" -g "${TARGET_GID:-open5gs}" open5gs 2>/dev/null || true
    fi

    # Ensure log and config directories exist and are owned by open5gs with 755 permissions
    mkdir -p /open5gs/logs /var/log/open5gs /tmp/config 2>/dev/null || true
    chown -R open5gs:open5gs /open5gs/logs /var/log/open5gs /tmp/config 2>/dev/null || chmod -R 755 /open5gs/logs /tmp/config 2>/dev/null || true
    chmod 755 /tmp/config 2>/dev/null || true
fi

# Helper function to drop privileges to open5gs user if running as root
run_as_open5gs() {
    if [ "$(id -u)" = "0" ]; then
        exec setpriv --reuid=open5gs --regid=open5gs --clear-groups "$@"
    else
        exec "$@"
    fi
}

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

    # Replace MCC, MNC, TAC, SST, SD placeholders (with environment fallbacks)
    sed -i "s/{{MCC}}/${MCC:-999}/g" /tmp/config/${NF}.yaml
    sed -i "s/{{MNC}}/${MNC:-70}/g" /tmp/config/${NF}.yaml
    sed -i "s/{{TAC}}/${TAC:-1}/g" /tmp/config/${NF}.yaml
    sed -i "s/{{SST}}/${SST:-1}/g" /tmp/config/${NF}.yaml
    sed -i "s/{{SD}}/${SD:-ffffff}/g" /tmp/config/${NF}.yaml

    # Replace UE_SUBNET and UE_GATEWAY placeholders
    sed -i "s|{{UE_SUBNET}}|${UE_SUBNET:-10.45.0.0/16}|g" /tmp/config/${NF}.yaml
    sed -i "s|{{UE_GATEWAY}}|${UE_GATEWAY:-10.45.0.1}|g" /tmp/config/${NF}.yaml

    # Replace LOG_LEVEL placeholder
    sed -i "s/{{LOG_LEVEL}}/${LOG_LEVEL:-info}/g" /tmp/config/${NF}.yaml

    # Replace DB_URI placeholder
    sed -i "s|{{DB_URI}}|${DB_URI:-mongodb://mongodb:27017/open5gs}|g" /tmp/config/${NF}.yaml

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
        run_as_open5gs open5gs-amfd -c /tmp/config/amf.yaml "$@"
        ;;
    smf)
        echo "Starting SMF..."
        run_as_open5gs open5gs-smfd -c /tmp/config/smf.yaml "$@"
        ;;
    upf)
        echo "Configuring UPF Network (TUN & NAT)..."
        sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true
        # Ensure /dev/net/tun is available
        if [ ! -c /dev/net/tun ]; then
            mkdir -p /dev/net
            mknod /dev/net/tun c 10 200
            chmod 600 /dev/net/tun
        fi

        # Delete existing TUN if present
        ip link delete ogstun dev ogstun 2>/dev/null || true

        # Create TUN interface owned by open5gs user
        ip tuntap add name ogstun mode tun user open5gs
        GW_IP="${UE_GATEWAY:-10.45.0.1}"
        if [ "${GW_IP#*/}" = "${GW_IP}" ]; then
            GW_IP="${GW_IP}/${UE_SUBNET#*/}"
        fi
        ip addr add ${GW_IP} dev ogstun
        ip link set ogstun up

        # Set up NAT/MASQUERADE to route UE traffic to the outer network
        iptables -t nat -A POSTROUTING -s ${UE_SUBNET:-10.45.0.0/16} ! -o ogstun -j MASQUERADE

        # Opt-in Network Egress Isolation Filtering
        if [ "${ENABLE_UE_EGRESS_ISOLATION:-false}" = "true" ] || [ "${ENABLE_UE_EGRESS_ISOLATION:-false}" = "True" ]; then
            echo "[UPF] Enabling Network Egress Isolation..."

            # Create dedicated FORWARD chain for UE Egress Isolation
            iptables -N UE_EGRESS 2>/dev/null || iptables -F UE_EGRESS
            iptables -C FORWARD -i ogstun -j UE_EGRESS 2>/dev/null || iptables -I FORWARD 1 -i ogstun -j UE_EGRESS

            # Parse and apply explicit ACCEPT rules for UE_ALLOWED_PRIVATE_EGRESS_SUBNETS if configured
            if [ -n "${UE_ALLOWED_PRIVATE_EGRESS_SUBNETS:-}" ]; then
                IFS=',' read -ra SUBNET_LIST <<< "${UE_ALLOWED_PRIVATE_EGRESS_SUBNETS}"
                for subnet in "${SUBNET_LIST[@]}"; do
                    subnet=$(echo "$subnet" | xargs)
                    if [ -n "$subnet" ]; then
                        echo "[UPF] Whitelisting permitted private egress destination: ${subnet}"
                        iptables -A UE_EGRESS -d "$subnet" -j ACCEPT
                    fi
                done
            fi

            # Block access to Host Loopback and Private RFC1918 subnets
            iptables -A UE_EGRESS -d 127.0.0.0/8 -j DROP
            iptables -A UE_EGRESS -d 10.0.0.0/8 -j DROP
            iptables -A UE_EGRESS -d 172.16.0.0/12 -j DROP
            iptables -A UE_EGRESS -d 192.168.0.0/16 -j DROP

            # Allow outbound traffic to public internet
            iptables -A UE_EGRESS -j ACCEPT
            echo "[UPF] Network Egress Isolation active: All unapproved private subnets (RFC1918) blocked for UE traffic."
        else
            echo "[UPF] Network Egress Isolation disabled (default: permissive forwarding)."
        fi

        echo "Starting UPF..."
        run_as_open5gs open5gs-upfd -c /tmp/config/upf.yaml "$@"
        ;;
    nrf)
        echo "Starting NRF..."
        run_as_open5gs open5gs-nrfd -c /tmp/config/nrf.yaml "$@"
        ;;
    udr)
        echo "Starting UDR..."
        run_as_open5gs open5gs-udrd -c /tmp/config/udr.yaml "$@"
        ;;
    udm)
        echo "Starting UDM..."
        run_as_open5gs open5gs-udmd -c /tmp/config/udm.yaml "$@"
        ;;
    ausf)
        echo "Starting AUSF..."
        run_as_open5gs open5gs-ausfd -c /tmp/config/ausf.yaml "$@"
        ;;
    pcf)
        echo "Starting PCF..."
        run_as_open5gs open5gs-pcfd -c /tmp/config/pcf.yaml "$@"
        ;;
    nssf)
        echo "Starting NSSF..."
        run_as_open5gs open5gs-nssfd -c /tmp/config/nssf.yaml "$@"
        ;;
    bsf)
        echo "Starting BSF..."
        run_as_open5gs open5gs-bsfd -c /tmp/config/bsf.yaml "$@"
        ;;
    webui)
        if [ "${PROVISION_SUBSCRIBERS:-false}" = "true" ] || [ "${PROVISION_SUBSCRIBERS:-false}" = "True" ]; then
            echo "Subscriber provisioning is enabled. Running provision script..."
            if [ "$(id -u)" = "0" ]; then
                setpriv --reuid=open5gs --regid=open5gs --clear-groups env NODE_PATH=/opt/open5gs/webui/node_modules /usr/bin/node /open5gs/provision.js
            else
                NODE_PATH=/opt/open5gs/webui/node_modules /usr/bin/node /open5gs/provision.js
            fi
        fi
        echo "Starting WebUI..."
        cd /opt/open5gs/webui
        run_as_open5gs /usr/bin/node server/index.js "$@"
        ;;
    *)
        echo "Unknown Network Function: $NF"
        usage
        ;;
esac
