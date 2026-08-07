#!/usr/bin/env bash
# =============================================================================
# Secure Home-Office Gateway (SHOG) — Main Installer
# One-command deployment for the full defensive stack.
# =============================================================================
# Usage: ./install.sh [options]
#   --mode <lite|full>  Deployment tier (default: full)
#   --skip-preflight    Skip preflight checks
#   --skip-secrets      Skip secret generation (use existing .env)
#   --profile <name>    Enable Docker profile: alerting, opencti, host-bouncer
#   --force             Overwrite existing secrets in .env
# =============================================================================
set -Eeuo pipefail

# Absolute paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
EXAMPLE_ENV="$SCRIPT_DIR/.env.example"
ORIGINAL_ARGS=("$@")

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
LAST_STEP="startup"
log_section() { LAST_STEP="$1"; echo -e "\n${BOLD}=== $1 ===${NC}"; }

# --- Parse arguments ---------------------------------------------------------
SKIP_PREFLIGHT=false
SKIP_SECRETS=false
COMPOSE_PROFILES=()
FORCE_REGEN=false
MODE="full"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-preflight)
            SKIP_PREFLIGHT=true
            shift
            ;;
        --mode)
            shift
            if [[ $# -eq 0 ]]; then
                log_error "--mode requires lite or full"
                exit 1
            fi
            MODE="$1"
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
            case "$1" in
                alerting|opencti|host-bouncer) ;;
                *)
                    log_error "Unsupported profile: $1 (expected: alerting, opencti, or host-bouncer)"
                    exit 1
                    ;;
            esac
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
            echo "  --mode <name>     Deployment tier: lite or full (default: full)"
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

if [[ "$MODE" != "lite" && "$MODE" != "full" ]]; then
    log_error "Unsupported mode: $MODE (expected: lite or full)"
    exit 1
fi

if [[ "$MODE" == "lite" && " ${COMPOSE_PROFILES[*]} " =~ " opencti " ]]; then
    log_error "The OpenCTI profile is not supported in lite mode; use --mode full"
    exit 1
fi

# The full tier activates the Wazuh/Filebeat services. Services without a
# profile remain the lightweight core used by both modes.
if [[ "$MODE" == "full" ]]; then
    COMPOSE_PROFILES=("siem" "${COMPOSE_PROFILES[@]}")
fi

INSTALL_REPRODUCE="./install.sh"
for arg in "${ORIGINAL_ARGS[@]}"; do
    printf -v quoted_arg '%q' "$arg"
    INSTALL_REPRODUCE+=" $quoted_arg"
done

# Every installer run gets a durable transcript. Re-executing once through
# tee avoids Bash /dev/fd process substitution, which is blocked on some
# hardened hosts. The inner process owns error handling and diagnostics.
if [[ "${SHOG_INSTALL_LOG_ACTIVE:-0}" != "1" ]]; then
    RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-${BASHPID}"
    INSTALL_RUN_DIR="$SCRIPT_DIR/logs/install/$RUN_ID"
    INSTALL_LOG="$INSTALL_RUN_DIR/install.log"
    mkdir -p "$INSTALL_RUN_DIR"
    chmod 700 "$INSTALL_RUN_DIR" 2>/dev/null || true
    touch "$INSTALL_LOG"
    printf '%s\n' "$INSTALL_REPRODUCE" > "$INSTALL_RUN_DIR/command.txt"

    set +e
    SHOG_INSTALL_LOG_ACTIVE=1 \
    SHOG_INSTALL_RUN_DIR="$INSTALL_RUN_DIR" \
    SHOG_INSTALL_LOG="$INSTALL_LOG" \
        bash "$SCRIPT_DIR/install.sh" "${ORIGINAL_ARGS[@]}" 2>&1 | tee -a "$INSTALL_LOG"
    INSTALL_STATUS=${PIPESTATUS[0]}
    exit "$INSTALL_STATUS"
fi

INSTALL_RUN_DIR="${SHOG_INSTALL_RUN_DIR:?missing installer run directory}"
INSTALL_LOG="${SHOG_INSTALL_LOG:?missing installer log path}"

on_install_error() {
    local exit_code="$1"
    local line_number="$2"
    local failed_command="$3"
    trap - ERR
    set +e
    log_error "Installation failed during '$LAST_STEP' (line $line_number, exit $exit_code)."
    "$SCRIPT_DIR/scripts/diagnose.sh" \
        --reason "Installer failed during $LAST_STEP at line $line_number" \
        --command "$failed_command" \
        --exit-code "$exit_code" \
        --mode "$MODE" \
        --source-log "$INSTALL_LOG" \
        --output-dir "$INSTALL_RUN_DIR/diagnostics" \
        --reproduce "$INSTALL_REPRODUCE" || true
    log_error "Review $INSTALL_RUN_DIR/diagnostics/next-steps.md"
    exit "$exit_code"
}

trap 'on_install_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

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
echo -e "Version: 1.0.0  |  https://github.com/MIjashRajthala/Sentinel-stack\n"
log_info "Deployment mode: $MODE"
log_info "Install log: $INSTALL_LOG"

# ============================================================================
# 1. PREFLIGHT CHECKS
# ============================================================================
log_section "Preflight Checks"

if [[ "$SKIP_PREFLIGHT" == true ]]; then
    log_warn "Skipping preflight checks (--skip-preflight specified)"
else
    log_info "Running preflight checks..."
    bash "$SCRIPT_DIR/scripts/preflight-check.sh" --mode "$MODE"
fi

# ============================================================================
# 2. CREATE .ENV FROM EXAMPLE
# ============================================================================
log_section "Environment Configuration"

if [[ ! -f "$ENV_FILE" ]]; then
    if [[ ! -f "$EXAMPLE_ENV" ]]; then
        log_error ".env.example not found at $EXAMPLE_ENV"
        false
    fi
    cp "$EXAMPLE_ENV" "$ENV_FILE"
    log_ok "Created .env from .env.example"
    log_warn "Review and edit $ENV_FILE before continuing"
else
    log_ok ".env already exists"
fi

# Record the selected tier for health checks and future reruns.
if grep -q '^SHOG_MODE=' "$ENV_FILE"; then
    sed -i.bak "s/^SHOG_MODE=.*/SHOG_MODE=$MODE/" "$ENV_FILE"
    rm -f "$ENV_FILE.bak"
else
    printf '\nSHOG_MODE=%s\n' "$MODE" >> "$ENV_FILE"
fi

# ============================================================================
# 3. SET KERNEL PARAMETERS
# ============================================================================
log_section "Kernel Parameters"

SYSCTL_CONF="/etc/sysctl.d/99-shog.conf"
if [[ "$MODE" == "lite" ]]; then
    log_ok "Skipping OpenSearch kernel tuning in lite mode"
elif [[ ! -f "$SYSCTL_CONF" ]]; then
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
PROFILE_ARGS=()
for profile in "${COMPOSE_PROFILES[@]}"; do
    PROFILE_ARGS+=(--profile "$profile")
done

docker compose "${PROFILE_ARGS[@]}" pull
log_ok "All images pulled"

# ============================================================================
# 8. DEPLOY STACK
# ============================================================================
log_section "Deploying Stack"

log_info "Starting core services (this may take several minutes)..."
docker compose "${PROFILE_ARGS[@]}" up -d --remove-orphans

# ============================================================================
# 9. WAIT FOR HEALTH CHECKS
# ============================================================================
log_section "Health Verification"

log_info "Waiting for services to become healthy..."
MAX_WAIT=240
[[ "$MODE" == "full" ]] && MAX_WAIT=480
[[ " ${COMPOSE_PROFILES[*]} " =~ " opencti " ]] && MAX_WAIT=900
WAITED=0

while [[ $WAITED -lt $MAX_WAIT ]]; do
    COMPOSE_STATUS=$(docker compose "${PROFILE_ARGS[@]}" ps --format json 2>/dev/null || true)
    UNHEALTHY=$(grep -c '"Health":"unhealthy"' <<< "$COMPOSE_STATUS" || true)
    STARTING=$(grep -c '"Health":"starting"' <<< "$COMPOSE_STATUS" || true)
    RUNNING=$(grep -c '"State":"running"' <<< "$COMPOSE_STATUS" || true)

    if [[ "$UNHEALTHY" -eq 0 && "$STARTING" -eq 0 && "$RUNNING" -gt 0 ]]; then
        log_ok "All services are healthy"
        break
    fi

    echo -ne "  Running: $RUNNING | Starting: $STARTING | Unhealthy: $UNHEALTHY\r"
    sleep 5
    WAITED=$((WAITED + 5))
done

if [[ $WAITED -ge $MAX_WAIT ]]; then
    log_error "Timed out waiting for services after ${MAX_WAIT}s"
    false
fi

# Verify the expected service set, not merely that at least one container runs.
bash "$SCRIPT_DIR/scripts/health-check.sh" --mode "$MODE"

# ============================================================================
# 10. POST-DEPLOYMENT CONFIGURATION
# ============================================================================
log_section "Post-Deployment"

# Give published endpoints a short grace period after container health succeeds.
[[ "$MODE" == "full" ]] && sleep 10 || sleep 2

# Get management IP from .env
MGMT_IP=$(grep "^MANAGEMENT_IP=" "$ENV_FILE" | cut -d= -f2- | tr -d '"' || true)
MGMT_IP="${MGMT_IP:-127.0.0.1}"

log_info "Service URLs (accessible from $MGMT_IP):"
echo ""
echo "  Portainer (Docker Management):  https://${MGMT_IP}:9443"
echo "  Uptime Kuma (Monitoring):       http://${MGMT_IP}:3001"
echo "  Pi-hole (DNS Admin):            http://${MGMT_IP}:8080/admin"

if [[ "$MODE" == "full" ]]; then
    echo "  Wazuh Dashboard (SIEM):         https://${MGMT_IP}:5601"
fi

if [[ " ${COMPOSE_PROFILES[*]} " =~ " opencti " ]]; then
    echo "  OpenCTI (Threat Intel):         http://${MGMT_IP}:8088"
fi

echo ""
log_info "Default credentials (CHANGE IMMEDIATELY):"
echo "  Portainer:     Set on first visit"
echo "  Uptime Kuma:   Set on first visit"
echo "  Pi-hole:       [from .env PIHOLE_WEBPASSWORD]"
if [[ "$MODE" == "full" ]]; then
    echo "  Wazuh:         admin / [from .env WAZUH_INDEXER_PASSWORD]"
fi

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
if [[ "$MODE" == "full" ]]; then
    echo "   docker compose --profile siem --profile alerting up -d"
else
    echo "   docker compose --profile alerting up -d"
fi
echo ""
echo "4. ${BOLD}Run health check${NC}:"
echo "   ./scripts/health-check.sh --mode $MODE --diagnose"
echo ""
echo "5. ${BOLD}Run backup${NC}:"
echo "   ./scripts/backup.sh"
echo ""
echo "6. ${BOLD}Run repeatable tests${NC}:"
echo "   ./scripts/test-stack.sh --mode $MODE --level static"
echo ""
echo "Documentation:"
echo "  docs/architecture.md    — Network & component architecture"
echo "  docs/pfsense-setup.md   — pfSense configuration guide"
echo "  docs/threat-model.md    — Threat model & controls"
echo "  docs/security-hardening.md — Hardening recommendations"
echo "  docs/troubleshooting.md — Common issues & fixes"
echo ""

log_ok "SHOG installation complete!"
log_ok "Install transcript saved to $INSTALL_LOG"
