#!/usr/bin/env bash
# =============================================================================
# SHOG Health Check Script
# Monitors the status of all SHOG services.
# =============================================================================
# Usage: ./scripts/health-check.sh [options]
#   --watch    Continuous monitoring mode (refresh every 30s)
#   --json     Output in JSON format
#   --alert    Send alert if any service is unhealthy
#   --mode     Expected service tier: lite or full
#   --diagnose Create a diagnostic bundle on failure
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

WATCH=false
JSON=false
ALERT=false
DIAGNOSE=false
QUIET=false
MODE="$(awk -F= '$1 == "SHOG_MODE" {print $2; exit}' "$PROJECT_DIR/.env" 2>/dev/null || true)"
MODE="${MODE:-full}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --watch)  WATCH=true; shift ;;
        --json)   JSON=true;  shift ;;
        --alert)  ALERT=true; shift ;;
        --diagnose) DIAGNOSE=true; shift ;;
        --quiet) QUIET=true; shift ;;
        --mode)
            [[ $# -ge 2 ]] || { echo "--mode requires lite or full" >&2; exit 2; }
            MODE="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: ./scripts/health-check.sh [options]"
            echo ""
            echo "Options:"
            echo "  --watch   Continuous monitoring mode (30s refresh)"
            echo "  --json    Output in JSON format"
            echo "  --alert   Send alert if services are unhealthy"
            echo "  --mode    Expected services: lite or full (default: .env/full)"
            echo "  --diagnose  Create a diagnostic bundle if unhealthy"
            echo "  --quiet   Suppress the human-readable table"
            echo "  --help    Show this help"
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ "$MODE" != "lite" && "$MODE" != "full" ]]; then
    echo "Invalid mode: $MODE (expected lite or full)" >&2
    exit 2
fi

# ============================================================================
# HEALTH CHECK FUNCTIONS
# ============================================================================

check_docker_service() {
    local name="$1"
    local status
    local health
    local state

    status=$(docker inspect --format='{{.State.Status}}' "$name" 2>/dev/null || echo "not_found")
    health=$(docker inspect --format='{{.State.Health.Status}}' "$name" 2>/dev/null || echo "none")
    state=$(docker inspect --format='{{.State.Running}}' "$name" 2>/dev/null || echo "false")

    echo "{\"name\":\"$name\",\"status\":\"$status\",\"health\":\"$health\",\"running\":$state}"
}

check_all_services() {
    local results=()
    local all_healthy=true

    # Lightweight core services
    SERVICES=(
        "shog-unbound"
        "shog-pihole"
        "shog-rsyslog"
        "shog-crowdsec"
        "shog-portainer"
        "shog-uptime-kuma"
    )

    if [[ "$MODE" == "full" ]]; then
        SERVICES+=(
            "shog-wazuh-indexer"
            "shog-wazuh-manager"
            "shog-wazuh-dashboard"
            "shog-wazuh-agent"
            "shog-filebeat"
        )
    fi

    # Optional services
    if docker inspect shog-crowdsec-bouncer &>/dev/null; then
        SERVICES+=("shog-crowdsec-bouncer")
    fi
    if docker inspect shog-alerting &>/dev/null; then
        SERVICES+=("shog-alerting")
    fi
    if docker inspect shog-opencti &>/dev/null; then
        SERVICES+=(
            "shog-opencti"
            "shog-opencti-redis"
            "shog-opencti-elasticsearch"
            "shog-opencti-minio"
            "shog-opencti-rabbitmq"
            "shog-opencti-connector-mitre"
        )
    fi

    for svc in "${SERVICES[@]}"; do
        result=$(check_docker_service "$svc")
        results+=("$result")

        health=$(echo "$result" | grep -o '"health":"[^"]*"' | cut -d'"' -f4)
        running=$(echo "$result" | grep -o '"running":[^,}]*' | cut -d: -f2)

        if [[ "$running" != "true" ]] || { [[ "$health" != "healthy" ]] && [[ "$health" != "none" ]]; }; then
            all_healthy=false
        fi
    done

    # Print results
    if [[ "$JSON" == true ]]; then
        printf '%s\n' "{\"timestamp\":\"$(date -Iseconds)\",\"services\":[$(IFS=,; echo "${results[*]}")],\"all_healthy\":$all_healthy}"
    elif [[ "$QUIET" == false ]]; then
        printf "\n${BOLD}%-35s %-12s %-12s %s${NC}\n" "CONTAINER" "STATUS" "HEALTH" "RUNNING"
        printf "%.80s\n" "--------------------------------------------------------------------------------"

        for result in "${results[@]}"; do
            name=$(echo "$result" | grep -o '"name":"[^"]*"' | cut -d'"' -f4)
            status=$(echo "$result" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
            health=$(echo "$result" | grep -o '"health":"[^"]*"' | cut -d'"' -f4)
            running=$(echo "$result" | grep -o '"running":[^,}]*' | cut -d: -f2)

            # Color coding
            if [[ "$running" == "true" && "$health" == "healthy" ]]; then
                sc="${GREEN}"; hc="${GREEN}"; rc="${GREEN}"
            elif [[ "$running" == "true" && "$health" == "starting" ]]; then
                sc="${YELLOW}"; hc="${YELLOW}"; rc="${GREEN}"
            elif [[ "$running" == "true" && "$health" == "none" ]]; then
                sc="${GREEN}"; hc="${YELLOW}"; rc="${GREEN}"
            elif [[ "$running" == "true" ]]; then
                sc="${GREEN}"; hc="${RED}"; rc="${GREEN}"
            else
                sc="${RED}"; hc="${RED}"; rc="${RED}"
                all_healthy=false
            fi

            printf "%-35b %b%-12s%b %b%-12s%b %b%-8s%b\n" \
                "$name" "$sc" "$status" "$NC" "$hc" "$health" "$NC" "$rc" "$running" "$NC"
        done

        # Disk usage
        echo ""
        echo -e "${BOLD}Docker Disk Usage:${NC}"
        docker system df --format "table {{.Type}}\t{{.TotalCount}}\t{{.Size}}\t{{.Reclaimable}}"

        # Uptime check for key services
        echo ""
        echo -e "${BOLD}Service Uptime:${NC}"
        docker ps --format "table {{.Names}}\t{{.Status}}" | grep shog- || true
    fi

    if [[ "$all_healthy" == false && "$ALERT" == true ]]; then
        # Simple alert via webhook if configured
        WEBHOOK_URL="${ALERTING_WEBHOOK_URL:-}"
        if [[ -n "$WEBHOOK_URL" ]]; then
            curl -s -X POST -H "Content-Type: application/json" \
                -d "{\"text\":\"SHOG Health Alert: One or more services are unhealthy on $(hostname)\"}" \
                "$WEBHOOK_URL" > /dev/null || true
        fi
    fi

    $all_healthy
}

# ============================================================================
# MAIN
# ============================================================================

if [[ "$WATCH" == true ]]; then
    while true; do
        clear
        echo -e "${BOLD}SHOG Health Monitor${NC} — $(date)"
        echo -e "Press Ctrl+C to exit\n"
        check_all_services || true
        sleep 30
    done
else
    if ! check_all_services; then
        if [[ "$DIAGNOSE" == true ]]; then
            "$SCRIPT_DIR/diagnose.sh" \
                --reason "One or more expected services are unhealthy" \
                --command "./scripts/health-check.sh --mode $MODE" \
                --exit-code 1 \
                --mode "$MODE" \
                --reproduce "./scripts/health-check.sh --mode $MODE --diagnose" || true
        fi
        exit 1
    fi
fi
