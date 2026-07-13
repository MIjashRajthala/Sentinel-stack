#!/usr/bin/env bash
# =============================================================================
# Secure Home-Office Gateway (SHOG) — Main Installer
# One-command deployment for the full defensive stack.
# =============================================================================
# Usage: ./install.sh [options]
#   --skip-preflight    Skip preflight checks
#   --skip-secrets      Skip secret generation (use existing .env)
#   --profile <name>    Enable Docker profile: alerting, opencti, host-bouncer
#   --force             Overwrite existing secrets in .env
# =============================================================================
set -euo pipefail

# Absolute paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
EXAMPLE_ENV="$SCRIPT_DIR/.env.example"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_section() { echo -e "\n${BOLD}=== $1 ===${NC}"; }

# --- Parse arguments ---------------------------------------------------------
SKIP_PREFLIGHT=false
SKIP_SECRETS=false
COMPOSE_PROFILES=()
FORCE_REGEN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-preflight)
            SKIP_PREFLIGHT=true
            shift
            ;;
        --skip-secrets)
            SKIP_SECRETS=true
            shift
            ;;
        --profile)
            shift
            if [[ $# -eq 0 ]]; then
                log_error "--profile requires a profile name"
                exit 1
            fi
            COMPOSE_PROFILES+=("$1")
            shift
            ;;
        --force)
            FORCE_REGEN=true
            shift
            ;;
        --help|-h)
            echo "Usage: ./install.sh [options]"
            echo ""
            echo "Options:"
            echo "  --skip-preflight  Skip preflight system checks"
            echo "  --skip-secrets    Skip automatic secret generation"
            echo "  --profile <name>  Enable a Docker Compose profile"
            echo "                    (alerting, opencti, host-bouncer)"
            echo "  --force           Overwrite existing secrets"
            echo "  --help, -h        Show this help message"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# ============================================================================
# 0. BANNER
# ============================================================================
cat <<'BANNER'
   _____                _      _   _       _ ___       ___                          _   
  / ____|              | |    | | | |     | / _ \     / _ \                        | |  
 | (___   ___ ___ _ __ | |_   | |_| |_  __| | | | |   | (_) | __ _ _   _  __ _  __ _| |_ 
  \___ \ / __/ _ \ '_ \| __|  | __| \/ / _` | | | |    > _ < / _` | | | |/ _` |/ _` | __|
  ____) | (_|  __/ | | | |_   | |_| >  < (_| | |_| |   | (_) | (_| | |_| | (_| | (_| | |_ 
 |_____/ \___\___|_| |_|\__|   \__/_/ \_\__,_|\___/     \___/ \__, |\__,_|\__, |\__,_|\__|
                                                               __/ |       __/ |          
                                                              |___/       |___/           
BANNER
echo -e "${BOLD}Secure Home-Office Gateway${NC} — Defensive Infrastructure Stack"
echo -e "Version: 1.0.0  |  https://github.com/your-org/shog\n"

# ============================================================================
# 1. PREFLIGHT CHECKS
# ============================================================================
log_section "Preflight Checks"

if [[ "$SKIP_PREFLIGHT" == true ]]; then
    log_warn "Skipping preflight checks (--skip-preflight specified)"
else
    log_info "Running preflight checks..."
    if ! bash "$SCRIPT_DIR/scripts/preflight-check.sh"; then
        log_error "Preflight checks failed. Resolve issues or use --skip-preflight to override."
        exit 1
    fi
fi

# ============================================================================
# 2. CREATE .ENV FROM EXAMPLE
# ============================================================================
log_section "Environment Configuration"

if [[ ! -f "$ENV_FILE" ]]; then
    if [[ ! -f "$EXAMPLE_ENV" ]]; then
        log_error ".env.example not found at $EXAMPLE_ENV"
        exit 1
    fi
    cp "$EXAMPLE_ENV" "$ENV_FILE"
    log_ok "Created .env from .env.example"
    log_warn "Review and edit $ENV_FILE before continuing"
else
    log_ok ".env already exists"
fi

# ============================================================================
# 3. SET KERNEL PARAMETERS
# ============================================================================
log_section "Kernel Parameters"

SYSCTL_CONF="/etc/sysctl.d/99-shog.conf"
if [[ ! -f "$SYSCTL_CONF" ]]; then
    log_info "Creating sysctl configuration at $SYSCTL_CONF"
    cat <<'EOF' | sudo tee "$SYSCTL_CONF" > /dev/null
# SHOG — Kernel parameters for Wazuh Indexer / Elasticsearch
vm.max_map_count = 262144
vm.swappiness = 10
EOF
    sudo sysctl --system > /dev/null 2>&1 || true
    log_ok "vm.max_map_count set to 262144"
else
    log_ok "sysctl configuration already exists"
fi

# ============================================================================
# 4. GENERATE SECRETS
# ============================================================================
log_section "Secret Generation"

if [[ "$SKIP_SECRETS" == true ]]; then
    log_warn "Skipping secret generation (--skip-secrets specified)"
else
    export FORCE_REGEN
    log_info "Generating secrets..."
    bash "$SCRIPT_DIR/scripts/generate-secrets.sh"
fi

# Fix .env permissions
chmod 600 "$ENV_FILE"
log_ok ".env permissions set to 600"

# ============================================================================
# 5. CREATE DOCKER NETWORKS (if they don't exist)
# ============================================================================
log_section "Docker Networks"

# Source network names from .env
source "$ENV_FILE"

for NET_NAME in shog-management shog-security shog-monitoring; do
    if docker network inspect "$NET_NAME" &>/dev/null; then
        log_ok "Docker network '$NET_NAME' already exists"
    else
        # Extract subnet from compose but use explicit names here
        log_info "Creating Docker network '$NET_NAME'..."
        # Networks are defined in compose; this is just a safety check
        log_ok "Network will be created by Docker Compose"
    fi
done

# ============================================================================
# 6. CREATE DIRECTORIES
# ============================================================================
log_section "Directory Setup"

mkdir -p "$SCRIPT_DIR/logs"
mkdir -p "$SCRIPT_DIR/backups"
log_ok "Created logs/ and backups/ directories"

# ============================================================================
# 7. PULL IMAGES
# ============================================================================
log_section "Pulling Container Images"

cd "$SCRIPT_DIR"

# Build compose profile arguments
PROFILE_ARGS=""
for profile in "${COMPOSE_PROFILES[@]}"; do
    PROFILE_ARGS="$PROFILE_ARGS --profile $profile"
done

docker compose $PROFILE_ARGS pull
log_ok "All images pulled"

# ============================================================================
# 8. DEPLOY STACK
# ============================================================================
log_section "Deploying Stack"

log_info "Starting core services (this may take several minutes)..."
docker compose $PROFILE_ARGS up -d --remove-orphans

# ============================================================================
# 9. WAIT FOR HEALTH CHECKS
# ============================================================================
log_section "Health Verification"

log_info "Waiting for services to become healthy..."
MAX_WAIT=300  # 5 minutes
WAITED=0

while [[ $WAITED -lt $MAX_WAIT ]]; do
    UNHEALTHY=$(docker compose ps --format json 2>/dev/null | \
        grep -c '"Health":"unhealthy"' || echo 0)
    STARTING=$(docker compose ps --format json 2>/dev/null | \
        grep -c '"Health":"starting"' || echo 0)
    RUNNING=$(docker compose ps --format json 2>/dev/null | \
        grep -c '"State":"running"' || echo 0)

    if [[ "$UNHEALTHY" -eq 0 && "$STARTING" -eq 0 && "$RUNNING" -gt 0 ]]; then
        log_ok "All services are healthy"
        break
    fi

    echo -ne "  Running: $RUNNING | Starting: $STARTING | Unhealthy: $UNHEALTHY\r"
    sleep 5
    WAITED=$((WAITED + 5))
done

if [[ $WAITED -ge $MAX_WAIT ]]; then
    log_warn "Timed out waiting for all services to become healthy"
    log_info "Run ./scripts/health-check.sh to check service status"
fi

# ============================================================================
# 10. POST-DEPLOYMENT CONFIGURATION
# ============================================================================
log_section "Post-Deployment"

# Wait a bit more for Wazuh initialization
sleep 10

# Get management IP from .env
MGMT_IP=$(grep "^MANAGEMENT_IP=" "$ENV_FILE" | cut -d= -f2 | tr -d '"')

log_info "Service URLs (accessible from $MGMT_IP):"
echo ""
echo "  Portainer (Docker Management):  https://${MGMT_IP}:9443"
echo "  Wazuh Dashboard (SIEM):         https://${MGMT_IP}:5601"
echo "  Uptime Kuma (Monitoring):       http://${MGMT_IP}:3001"
echo "  Pi-hole (DNS Admin):            http://${MGMT_IP}:8080/admin"

if [[ " ${COMPOSE_PROFILES[*]} " =~ " opencti " ]]; then
    echo "  OpenCTI (Threat Intel):         http://${MGMT_IP}:8088"
fi

echo ""
log_info "Default credentials (CHANGE IMMEDIATELY):"
echo "  Portainer:     Set on first visit"
echo "  Wazuh:         admin / [from .env WAZUH_INDEXER_PASSWORD]"
echo "  Uptime Kuma:   Set on first visit"
echo "  Pi-hole:       [from .env PIHOLE_WEBPASSWORD]"

# ============================================================================
# 11. NEXT STEPS
# ============================================================================
log_section "Next Steps"

echo ""
echo "1. ${BOLD}Configure pfSense${NC}: Follow docs/pfsense-setup.md"
echo "   - Set Pi-hole (${PIHOLE_IP:-172.28.1.2}) as DNS for LAN"
echo "   - Forward syslog to this Docker host (${RSYSLOG_IP:-172.28.1.4})"
echo "   - Configure Suricata IDS with EVE JSON output"
echo ""
echo "2. ${BOLD}Verify DNS${NC}: Test from a LAN client:"
echo "   dig @${PIHOLE_IP:-172.28.1.2} cloudflare.com"
echo ""
echo "3. ${BOLD}Configure alerts${NC}: Set webhook/SMTP in .env, then:"
echo "   docker compose --profile alerting up -d"
echo ""
echo "4. ${BOLD}Run health check${NC}:"
echo "   ./scripts/health-check.sh"
echo ""
echo "5. ${BOLD}Run backup${NC}:"
echo "   ./scripts/backup.sh"
echo ""
echo "Documentation:"
echo "  docs/architecture.md    — Network & component architecture"
echo "  docs/pfsense-setup.md   — pfSense configuration guide"
echo "  docs/threat-model.md    — Threat model & controls"
echo "  docs/security-hardening.md — Hardening recommendations"
echo "  docs/troubleshooting.md — Common issues & fixes"
echo ""

log_ok "SHOG installation complete!"
