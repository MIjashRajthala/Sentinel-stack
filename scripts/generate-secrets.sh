#!/usr/bin/env bash
# =============================================================================
# SHOG Secret Generator
# Generates strong random secrets for all services and updates .env
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}   $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }

# Check for required tools
if ! command -v openssl &>/dev/null; then
    echo "ERROR: openssl is required but not installed."
    echo "Install with: sudo apt install openssl"
    exit 1
fi

# Ensure .env exists
if [[ ! -f "$ENV_FILE" ]]; then
    log_warn ".env file not found - creating from .env.example"
    cp "$PROJECT_DIR/.env.example" "$ENV_FILE"
fi

# Backup .env before modification
BACKUP_SUFFIX="$(date +%Y%m%d_%H%M%S)"
cp "$ENV_FILE" "$ENV_FILE.bak.$BACKUP_SUFFIX"
log_info "Backed up existing .env to .env.bak.$BACKUP_SUFFIX"

# Helper: generate random string of specified length
# Usage: generate_secret <length>
generate_secret() {
    local length="${1:-32}"
    openssl rand -base64 "${length}" | tr -dc 'a-zA-Z0-9' | head -c "${length}"
}

# Helper: generate UUID v4 style string
generate_uuid() {
    local hex
    hex=$(openssl rand -hex 16)
    printf "%s%s-%s%s-%s%s-%s%s-%s" \
        "${hex:0:8}" "" "${hex:8:4}" "" "${hex:12:4}" "" \
        "${hex:16:4}" "" "${hex:20:12}"
}

# Helper: update or append a variable in .env
# Usage: set_env_var <VAR_NAME> <value>
set_env_var() {
    local var_name="$1"
    local var_value="$2"
    local escaped_value
    escaped_value=$(printf '%s\n' "$var_value" | sed -e 's/[&/]/\\&/g')

    if grep -q "^${var_name}=" "$ENV_FILE" 2>/dev/null; then
        # Variable exists - update it if empty or if FORCE_REGEN is set
        local current_value
        current_value=$(grep "^${var_name}=" "$ENV_FILE" | cut -d= -f2-)
        if [[ -z "$current_value" ]] || [[ "${FORCE_REGEN:-false}" == "true" ]]; then
            sed -i "s|^${var_name}=.*|${var_name}=${escaped_value}|" "$ENV_FILE"
            log_ok "Generated ${var_name}"
        else
            log_info "${var_name} already set - skipping (use FORCE_REGEN=true to overwrite)"
        fi
    else
        # Variable doesn't exist - append it
        echo "${var_name}=${var_value}" >> "$ENV_FILE"
        log_ok "Generated ${var_name}"
    fi
}

log_info "Generating secrets..."

# ============================================================================
# PI-HOLE
# ============================================================================
set_env_var "PIHOLE_WEBPASSWORD" "$(generate_secret 24)"

# ============================================================================
# CROWDSEC
# ============================================================================
set_env_var "CROWDSEC_BOUNCER_KEY" "$(generate_secret 32)"

# ============================================================================
# WAZUH
# ============================================================================
set_env_var "WAZUH_INDEXER_PASSWORD" "$(generate_secret 32)"
set_env_var "WAZUH_API_PASSWORD" "$(generate_secret 32)"

# ============================================================================
# ALERTING (only if webhook or SMTP is configured)
# ============================================================================
if grep -qE "^ALERTING_WEBHOOK_URL=." "$ENV_FILE" 2>/dev/null || \
   grep -qE "^ALERTING_SMTP_HOST=." "$ENV_FILE" 2>/dev/null; then
    log_info "Alerting configuration detected - ensuring secrets are present"
fi

# ============================================================================
# OPENCTI (only if enabled)
# ============================================================================
set_env_var "OPENCTI_ADMIN_PASSWORD" "$(generate_secret 24)"
set_env_var "OPENCTI_ADMIN_TOKEN" "$(generate_uuid)"
set_env_var "OPENCTI_ES_PASSWORD" "$(generate_secret 32)"
set_env_var "OPENCTI_MINIO_ACCESS_KEY" "$(generate_secret 20)"
set_env_var "OPENCTI_MINIO_SECRET_KEY" "$(generate_secret 32)"
set_env_var "OPENCTI_RABBITMQ_PASS" "$(generate_secret 24)"
set_env_var "OPENCTI_CONNECTOR_MITRE_ID" "$(generate_uuid)"

log_info "Secret generation complete."
log_info "Review .env and adjust any settings before deployment."
log_warn "Protect your .env file: chmod 600 .env"
