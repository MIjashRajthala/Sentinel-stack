#!/usr/bin/env bash
# =============================================================================
# SHOG Preflight Check Script
# Validates system readiness before deployment.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$PROJECT_DIR/.env" 2>/dev/null || true

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
BOLD='\033[1m'

PASS=0
WARN=0
FAIL=0
MODE="full"

usage() {
    cat <<'EOF'
Usage: ./scripts/preflight-check.sh [--mode lite|full]

  lite  DNS filtering, logging, CrowdSec, Portainer, and Uptime Kuma
  full  Lite services plus Wazuh SIEM and Filebeat (default)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)
            [[ $# -ge 2 ]] || { echo "--mode requires lite or full" >&2; exit 2; }
            MODE="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ "$MODE" != "lite" && "$MODE" != "full" ]]; then
    echo "Invalid mode: $MODE (expected lite or full)" >&2
    exit 2
fi

log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; ((++PASS)); }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; ((++WARN)); }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; ((++FAIL)); }
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_section() { echo -e "\n${BOLD}=== $1 ===${NC}"; }

PORT_CONFLICT_LISTENERS=""

# Return success when an IPv4 listener would conflict with the requested bind.
# A service bound to 127.0.0.53 does not conflict with a container published on
# a different specific address such as 192.168.1.10.
port_has_conflict() {
    local bind_ip="$1"
    local port="$2"
    local listeners line endpoint listener_ip

    command -v ss >/dev/null 2>&1 || return 2
    listeners=$(ss -H -lntu "( sport = :$port )" 2>/dev/null || true)
    PORT_CONFLICT_LISTENERS=""

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        endpoint=$(awk '{print $5}' <<< "$line")
        listener_ip="${endpoint%:*}"
        listener_ip="${listener_ip#[}"
        listener_ip="${listener_ip%]}"
        listener_ip="${listener_ip%%%*}"

        # IPv6-only listeners do not block an explicit IPv4 Docker publish.
        [[ "$listener_ip" == *:* ]] && continue

        if [[ "$bind_ip" == "0.0.0.0" || "$listener_ip" == "$bind_ip" || \
              "$listener_ip" == "0.0.0.0" || "$listener_ip" == "*" ]]; then
            PORT_CONFLICT_LISTENERS+="${line}"$'\n'
        fi
    done <<< "$listeners"

    [[ -n "$PORT_CONFLICT_LISTENERS" ]]
}

check_host_port() {
    local bind_ip="$1"
    local port="$2"
    local label="$3"
    local severity="${4:-fail}"
    local status

    if port_has_conflict "$bind_ip" "$port"; then
        if [[ "$severity" == "warn" ]]; then
            log_warn "Port $port ($label) conflicts on $bind_ip"
        else
            log_fail "Port $port ($label) conflicts on $bind_ip"
        fi
        log_info "  $(head -n 1 <<< "$PORT_CONFLICT_LISTENERS")"
        return 0
    else
        status=$?
    fi

    if [[ "$status" -eq 2 ]]; then
        log_warn "Cannot inspect port $port ($label) because ss is unavailable"
    else
        log_pass "Port $port ($label) available on $bind_ip"
    fi
}

# ---------------------------------------------------------------------------
# 1. OS CHECK
# ---------------------------------------------------------------------------
log_section "Operating System"
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    if [[ "$ID" == "ubuntu" ]]; then
        UBUNTU_VERSION="${VERSION_ID%%.*}"
        if [[ "$UBUNTU_VERSION" -ge 22 ]]; then
            log_pass "Ubuntu $VERSION_ID (supported, minimum 22.04)"
        else
            log_fail "Ubuntu $VERSION_ID (minimum 22.04 LTS required)"
        fi
    else
        log_warn "Distribution: $PRETTY_NAME (Ubuntu 22.04+ strongly recommended)"
    fi
else
    log_fail "Cannot determine OS. Ubuntu 22.04+ required."
fi

# ---------------------------------------------------------------------------
# 2. KERNEL CHECK
# ---------------------------------------------------------------------------
KERNEL_MAJOR=$(uname -r | cut -d. -f1)
KERNEL_MINOR=$(uname -r | cut -d. -f2)
if [[ "$KERNEL_MAJOR" -gt 5 ]] || [[ "$KERNEL_MAJOR" -eq 5 && "$KERNEL_MINOR" -ge 15 ]]; then
    log_pass "Kernel $(uname -r) (5.15+ recommended)"
else
    log_warn "Kernel $(uname -r) (5.15+ recommended for optimal cgroup support)"
fi

# ---------------------------------------------------------------------------
# 3. CPU CHECK
# ---------------------------------------------------------------------------
log_section "CPU Resources"
CPU_COUNT=$(nproc)
if [[ "$MODE" == "lite" && "$CPU_COUNT" -ge 2 ]]; then
    log_pass "$CPU_COUNT vCPUs (2+ recommended for lite mode)"
elif [[ "$MODE" == "lite" && "$CPU_COUNT" -ge 1 ]]; then
    log_warn "$CPU_COUNT vCPU (2 recommended for lite mode)"
elif [[ "$MODE" == "full" && "$CPU_COUNT" -ge 4 ]]; then
    log_pass "$CPU_COUNT vCPUs (4+ recommended for full mode)"
elif [[ "$MODE" == "full" && "$CPU_COUNT" -ge 2 ]]; then
    log_warn "$CPU_COUNT vCPUs (4+ recommended for full mode)"
else
    log_fail "$CPU_COUNT vCPUs is below the minimum for $MODE mode"
fi

# ---------------------------------------------------------------------------
# 4. RAM CHECK
# ---------------------------------------------------------------------------
log_section "Memory Resources"
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_MB=$((TOTAL_RAM_KB / 1024))
TOTAL_RAM_GB=$((TOTAL_RAM_MB / 1024))
if [[ "$MODE" == "lite" && "$TOTAL_RAM_MB" -ge 4096 ]]; then
    log_pass "${TOTAL_RAM_GB} GB RAM (4+ GB recommended for lite mode)"
elif [[ "$MODE" == "lite" && "$TOTAL_RAM_MB" -ge 2048 ]]; then
    log_warn "${TOTAL_RAM_GB} GB RAM (2 GB minimum; 4 GB recommended for lite mode)"
elif [[ "$MODE" == "full" && "$TOTAL_RAM_MB" -ge 8192 ]]; then
    log_pass "${TOTAL_RAM_GB} GB RAM (8+ GB recommended for full mode)"
elif [[ "$MODE" == "full" && "$TOTAL_RAM_MB" -ge 4096 ]]; then
    log_warn "${TOTAL_RAM_GB} GB RAM (4 GB minimum; 8+ GB recommended for full mode)"
else
    log_fail "${TOTAL_RAM_GB} GB RAM is below the minimum for $MODE mode"
fi

# ---------------------------------------------------------------------------
# 5. DISK CHECK
# ---------------------------------------------------------------------------
log_section "Disk Resources"
DISK_AVAIL_GB=$(df -BG "$PROJECT_DIR" | tail -1 | awk '{print $4}' | tr -d 'G')
if [[ "$MODE" == "lite" && "$DISK_AVAIL_GB" -ge 40 ]]; then
    log_pass "${DISK_AVAIL_GB} GB available (40+ GB recommended for lite mode)"
elif [[ "$MODE" == "lite" && "$DISK_AVAIL_GB" -ge 20 ]]; then
    log_warn "${DISK_AVAIL_GB} GB available (20 GB minimum; shorten retention)"
elif [[ "$MODE" == "full" && "$DISK_AVAIL_GB" -ge 100 ]]; then
    log_pass "${DISK_AVAIL_GB} GB available (100+ GB recommended for full mode)"
elif [[ "$MODE" == "full" && "$DISK_AVAIL_GB" -ge 50 ]]; then
    log_warn "${DISK_AVAIL_GB} GB available (50 GB minimum; 100+ GB recommended)"
else
    log_fail "${DISK_AVAIL_GB} GB available is below the minimum for $MODE mode"
fi

# ---------------------------------------------------------------------------
# 6. DOCKER ENGINE CHECK
# ---------------------------------------------------------------------------
log_section "Docker Engine"
if command -v docker &>/dev/null; then
    DOCKER_VERSION=$(docker --version | awk '{print $3}' | tr -d ',')
    log_pass "Docker Engine $DOCKER_VERSION installed"

    if docker info &>/dev/null; then
        log_pass "Docker daemon is running"
    else
        log_fail "Docker daemon is not running. Start with: sudo systemctl start docker"
    fi
else
    log_fail "Docker Engine not installed. Install: https://docs.docker.com/engine/install/ubuntu/"
fi

# ---------------------------------------------------------------------------
# 7. DOCKER COMPOSE PLUGIN CHECK
# ---------------------------------------------------------------------------
if docker compose version &>/dev/null; then
    COMPOSE_VERSION=$(docker compose version --short)
    log_pass "Docker Compose plugin $COMPOSE_VERSION installed"
else
    log_fail "Docker Compose plugin not installed. Install: sudo apt install docker-compose-plugin"
fi

# ---------------------------------------------------------------------------
# 8. KERNEL PARAMETERS
# ---------------------------------------------------------------------------
log_section "Kernel Settings"

# vm.max_map_count is only required by the Wazuh/OpenSearch tier.
CURRENT_MAX_MAP=$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)
if [[ "$MODE" == "lite" ]]; then
    log_pass "vm.max_map_count is not required in lite mode"
elif [[ "$CURRENT_MAX_MAP" -ge 262144 ]]; then
    log_pass "vm.max_map_count = $CURRENT_MAX_MAP (>= 262144)"
else
    log_warn "vm.max_map_count = $CURRENT_MAX_MAP (set to 262144 for Wazuh Indexer)"
    log_info "  Run: echo 'vm.max_map_count=262144' | sudo tee -a /etc/sysctl.d/99-shog.conf"
    log_info "  Then: sudo sysctl --system"
fi

# Check for swap (should exist but not be heavily relied upon)
SWAP_TOTAL=$(free -m | awk '/Swap:/ {print $2}')
if [[ "$SWAP_TOTAL" -gt 0 ]]; then
    log_pass "Swap: ${SWAP_TOTAL} MB available"
else
    log_warn "No swap configured (recommend 2-4 GB for stability)"
fi

# ---------------------------------------------------------------------------
# 9. PORT CONFLICT CHECK
# ---------------------------------------------------------------------------
log_section "Port Availability"

# Check the actual bind addresses and both TCP and UDP listeners. This avoids a
# false conflict between systemd-resolved on 127.0.0.53 and Pi-hole on the LAN.
PIHOLE_DNS_BIND_IP="${PIHOLE_DNS_BIND_IP:-0.0.0.0}"
PIHOLE_WEB_IP="${PIHOLE_WEB_IP:-127.0.0.1}"
MANAGEMENT_IP="${MANAGEMENT_IP:-127.0.0.1}"

check_host_port "127.0.0.1" 5335 "Unbound DNS"
check_host_port "$PIHOLE_DNS_BIND_IP" 53 "Pi-hole DNS"
if [[ "$PIHOLE_DNS_BIND_IP" == "0.0.0.0" ]]; then
    log_info "  Set PIHOLE_DNS_BIND_IP to a stable LAN address to coexist with systemd-resolved"
fi
check_host_port "$PIHOLE_WEB_IP" 8080 "Pi-hole web"
check_host_port "0.0.0.0" 514 "rsyslog"

if [[ "$MODE" == "full" ]]; then
    check_host_port "$MANAGEMENT_IP" 5601 "Wazuh Dashboard"
fi

check_host_port "$MANAGEMENT_IP" 9443 "Portainer HTTPS"
check_host_port "$MANAGEMENT_IP" 9000 "Portainer HTTP"
check_host_port "$MANAGEMENT_IP" 3001 "Uptime Kuma"
check_host_port "$MANAGEMENT_IP" 8088 "OpenCTI optional profile" warn

# ---------------------------------------------------------------------------
# 10. NETWORK CONFLICT CHECK
# ---------------------------------------------------------------------------
log_section "Network Conflicts"

for SUBNET_NAME in MGMT_SUBNET SEC_SUBNET MON_SUBNET; do
    SUBNET_VALUE="${!SUBNET_NAME:-}"
    if [[ -z "$SUBNET_VALUE" ]]; then
        case "$SUBNET_NAME" in
            MGMT_SUBNET) SUBNET_VALUE="172.27.1.0/24" ;;
            SEC_SUBNET)  SUBNET_VALUE="172.28.1.0/24" ;;
            MON_SUBNET)  SUBNET_VALUE="172.29.1.0/24" ;;
        esac
    fi

    # Check if subnet overlaps with existing routes
    if ip route | grep -q "${SUBNET_VALUE%/*}"; then
        log_warn "Subnet $SUBNET_NAME ($SUBNET_VALUE) may conflict with existing routes"
    else
        log_pass "Subnet $SUBNET_NAME ($SUBNET_VALUE) appears available"
    fi
done

# ---------------------------------------------------------------------------
# 11. FIREWALL / UFW CHECK
# ---------------------------------------------------------------------------
log_section "Host Firewall"
if command -v ufw &>/dev/null; then
    UFW_STATUS=$(ufw status numbered 2>/dev/null | head -1 || echo "unknown")
    if echo "$UFW_STATUS" | grep -qi "active"; then
        log_warn "UFW is active — ensure Docker network subnets are allowed"
        log_info "  Allow management subnet: sudo ufw allow from ${MGMT_SUBNET:-172.27.1.0/24}"
    else
        log_pass "UFW is inactive (configure after deployment if needed)"
    fi
else
    log_info "UFW not installed — consider installing for host-level protection"
fi

# ---------------------------------------------------------------------------
# 12. SELINUX / APPARMOR
# ---------------------------------------------------------------------------
if command -v getenforce &>/dev/null; then
    SELINUX_STATUS=$(getenforce)
    if [[ "$SELINUX_STATUS" == "Enforcing" ]]; then
        log_warn "SELinux is enforcing — may require policy adjustments for Docker"
    else
        log_pass "SELinux status: $SELINUX_STATUS"
    fi
fi

if command -v aa-status &>/dev/null; then
    log_pass "AppArmor is available"
fi

# ---------------------------------------------------------------------------
# 13. TIME SYNC
# ---------------------------------------------------------------------------
log_section "Time Synchronisation"
if timedatectl status 2>/dev/null | grep -q "NTP enabled: yes"; then
    log_pass "NTP time synchronisation enabled"
else
    log_warn "NTP may not be enabled — accurate time is critical for SIEM correlation"
    log_info "  Enable: sudo timedatectl set-ntp true"
fi

# ---------------------------------------------------------------------------
# SUMMARY
# ---------------------------------------------------------------------------
echo -e "\n${BOLD}========================================${NC}"
echo -e "${BOLD}  Preflight Check Summary${NC}"
echo -e "${BOLD}========================================${NC}"
echo -e "  Mode:    $MODE"
echo -e "  ${GREEN}Passed:  $PASS${NC}"
echo -e "  ${YELLOW}Warnings: $WARN${NC}"
echo -e "  ${RED}Failed:  $FAIL${NC}"

if [[ "$FAIL" -gt 0 ]]; then
    echo -e "\n${RED}${BOLD}FAILED — resolve failures before continuing.${NC}"
    exit 1
elif [[ "$WARN" -gt 0 ]]; then
    echo -e "\n${YELLOW}${BOLD}PASSED WITH WARNINGS — review warnings above.${NC}"
    echo -e "Deployment can continue but may require manual fixes."
    exit 0
else
    echo -e "\n${GREEN}${BOLD}ALL CHECKS PASSED — ready for deployment.${NC}"
    exit 0
fi
