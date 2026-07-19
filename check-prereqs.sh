#!/usr/bin/env bash
#
# Open5GS Deploy - Host Pre-flight Check Script
# Verifies system requirements, kernel modules, and environment setup.
#

set -euo pipefail

RED='\030[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

ERRORS=0
WARNINGS=0

echo -e "=== Open5GS Deploy Host Pre-flight Checks ===\n"

# 1. Check Docker & Docker Compose
echo -n "[1/5] Checking Docker Engine... "
if command -v docker &>/dev/null; then
    DOCKER_VER=$(docker --version | awk '{print $3}' | tr -d ',')
    echo -e "${GREEN}OK${NC} (v${DOCKER_VER})"
else
    echo -e "${RED}FAIL${NC} - Docker CLI is not installed!"
    ERRORS=$((ERRORS + 1))
fi

echo -n "[2/5] Checking Docker Compose... "
if docker compose version &>/dev/null; then
    COMPOSE_VER=$(docker compose version | awk '{print $4}')
    echo -e "${GREEN}OK${NC} (${COMPOSE_VER})"
else
    echo -e "${RED}FAIL${NC} - Docker Compose plugin is not installed!"
    ERRORS=$((ERRORS + 1))
fi

# 2. Check SCTP Kernel Module (required by AMF)
echo -n "[3/5] Checking SCTP kernel module... "
if lsmod | grep -q sctp &>/dev/null || modprobe -n sctp &>/dev/null; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${YELLOW}WARN${NC} - SCTP kernel module not loaded! Run: sudo modprobe sctp"
    WARNINGS=$((WARNINGS + 1))
fi

# 3. Check TUN Interface Device (required by UPF)
echo -n "[4/5] Checking TUN interface support... "
if [ -c /dev/net/tun ] || lsmod | grep -q tun &>/dev/null || modprobe -n tun &>/dev/null; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${YELLOW}WARN${NC} - TUN kernel module not active! Run: sudo modprobe tun"
    WARNINGS=$((WARNINGS + 1))
fi

# 4. Check IPv4 Forwarding
echo -n "[5/5] Checking IPv4 forwarding... "
IP_FORWARD=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "0")
if [ "${IP_FORWARD}" = "1" ]; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${YELLOW}WARN${NC} - net.ipv4.ip_forward is disabled! Enable via: sudo sysctl -w net.ipv4.ip_forward=1"
    WARNINGS=$((WARNINGS + 1))
fi

# 5. Check .env file
echo -n "[Check] Environment file (.env)... "
if [ -f .env ]; then
    echo -e "${GREEN}OK${NC}"
else
    echo -e "${YELLOW}MISSING${NC} - .env not found. Creating from env.sample..."
    cp env.sample .env
    echo -e "${GREEN}Created .env from env.sample${NC}"
fi

echo -e "\n=== Summary ==="
if [ ${ERRORS} -eq 0 ] && [ ${WARNINGS} -eq 0 ]; then
    echo -e "${GREEN}All pre-flight checks passed! Your host system is ready.${NC}"
    exit 0
elif [ ${ERRORS} -eq 0 ]; then
    echo -e "${YELLOW}Pre-flight completed with ${WARNINGS} warning(s). Recommended to resolve warnings before starting stack.${NC}"
    exit 0
else
    echo -e "${RED}Pre-flight failed with ${ERRORS} error(s). Please fix critical errors before proceeding.${NC}"
    exit 1
fi
