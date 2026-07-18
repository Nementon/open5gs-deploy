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

case "$NF" in
    amf)
        echo "Starting AMF..."
        exec open5gs-amfd -c /open5gs/config/amf.yaml "$@"
        ;;
    smf)
        echo "Starting SMF..."
        exec open5gs-smfd -c /open5gs/config/smf.yaml "$@"
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
        exec open5gs-upfd -c /open5gs/config/upf.yaml "$@"
        ;;
    nrf)
        echo "Starting NRF..."
        exec open5gs-nrfd -c /open5gs/config/nrf.yaml "$@"
        ;;
    udr)
        echo "Starting UDR..."
        exec open5gs-udrd -c /open5gs/config/udr.yaml "$@"
        ;;
    udm)
        echo "Starting UDM..."
        exec open5gs-udmd -c /open5gs/config/udm.yaml "$@"
        ;;
    ausf)
        echo "Starting AUSF..."
        exec open5gs-ausfd -c /open5gs/config/ausf.yaml "$@"
        ;;
    pcf)
        echo "Starting PCF..."
        exec open5gs-pcfd -c /open5gs/config/pcf.yaml "$@"
        ;;
    nssf)
        echo "Starting NSSF..."
        exec open5gs-nssfd -c /open5gs/config/nssf.yaml "$@"
        ;;
    bsf)
        echo "Starting BSF..."
        exec open5gs-bsfd -c /open5gs/config/bsf.yaml "$@"
        ;;
    webui)
        echo "Starting WebUI..."
        cd /usr/lib/node_modules/open5gs
        exec /usr/bin/node server/index.js "$@"
        ;;
    *)
        echo "Unknown Network Function: $NF"
        usage
        ;;
esac
