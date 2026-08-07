#!/usr/bin/env bash
# Prepare non-secret host-specific settings shared by install and test flows.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${SHOG_ENV_FILE:-$PROJECT_DIR/.env}"
EXAMPLE_ENV="${SHOG_ENV_EXAMPLE:-$PROJECT_DIR/.env.example}"
MODE="full"

usage() {
    cat <<'EOF'
Usage: ./scripts/prepare-environment.sh [--mode lite|full]

Creates .env when needed, records the deployment mode, and selects a specific
host IPv4 address for Pi-hole DNS without overwriting an existing choice.
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

if [[ ! -f "$ENV_FILE" ]]; then
    [[ -f "$EXAMPLE_ENV" ]] || { echo "Missing environment template: $EXAMPLE_ENV" >&2; exit 1; }
    cp "$EXAMPLE_ENV" "$ENV_FILE"
    echo "Created $ENV_FILE from the environment template"
fi

set_env_value() {
    local key="$1"
    local value="$2"
    local escaped
    escaped=$(printf '%s\n' "$value" | sed -e 's/[&|]/\\&/g')

    if grep -q "^${key}=" "$ENV_FILE"; then
        sed -i.bak "s|^${key}=.*|${key}=${escaped}|" "$ENV_FILE"
        rm -f "$ENV_FILE.bak"
    else
        printf '\n%s=%s\n' "$key" "$value" >> "$ENV_FILE"
    fi
}

get_env_value() {
    local key="$1"
    sed -n "s/^${key}=//p" "$ENV_FILE" | tail -n 1
}

detect_primary_ipv4() {
    local detected=""

    if command -v ip >/dev/null 2>&1; then
        detected=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '
            { for (i = 1; i <= NF; i++) if ($i == "src" && (i + 1) <= NF) { print $(i + 1); exit } }
        ')
    fi

    if [[ -z "$detected" ]] && command -v hostname >/dev/null 2>&1; then
        detected=$(hostname -I 2>/dev/null | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+\./) { print $i; exit } }')
    fi

    printf '%s' "$detected"
}

set_env_value "SHOG_MODE" "$MODE"

PIHOLE_BIND_IP="$(get_env_value PIHOLE_DNS_BIND_IP)"
if [[ -z "$PIHOLE_BIND_IP" || "$PIHOLE_BIND_IP" == "auto" ]]; then
    PIHOLE_BIND_IP="$(detect_primary_ipv4)"
    if [[ -z "$PIHOLE_BIND_IP" ]]; then
        echo "Could not detect a primary IPv4 address; set PIHOLE_DNS_BIND_IP in $ENV_FILE" >&2
        exit 1
    fi
    set_env_value "PIHOLE_DNS_BIND_IP" "$PIHOLE_BIND_IP"
    echo "Selected PIHOLE_DNS_BIND_IP=$PIHOLE_BIND_IP"
else
    echo "Using configured PIHOLE_DNS_BIND_IP=$PIHOLE_BIND_IP"
fi

chmod 600 "$ENV_FILE" 2>/dev/null || true
