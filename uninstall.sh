#!/usr/bin/env bash
# =============================================================================
# SHOG Uninstall Script
# Removes the stack with explicit warnings about data deletion.
# =============================================================================
# Usage: ./uninstall.sh [options]
#   --volumes   Also delete named Docker volumes (PERMANENT DATA LOSS)
#   --images    Also delete SHOG container images
#   --yes       Skip confirmation prompts (USE WITH CAUTION)
#   --purge     Remove configs, .env, logs, and backups too
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

DELETE_VOLUMES=false
DELETE_IMAGES=false
SKIP_CONFIRM=false
PURGE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --volumes) DELETE_VOLUMES=true; shift ;;
        --images)  DELETE_IMAGES=true;  shift ;;
        --yes)     SKIP_CONFIRM=true;   shift ;;
        --purge)   PURGE=true; DELETE_VOLUMES=true; DELETE_IMAGES=true; shift ;;
        --help|-h)
            echo "Usage: ./uninstall.sh [options]"
            echo ""
            echo "Options:"
            echo "  --volumes   Delete named Docker volumes (PERMANENT DATA LOSS)"
            echo "  --images    Delete SHOG container images"
            echo "  --purge     Full removal including configs, .env, logs, backups"
            echo "  --yes       Skip confirmation prompts"
            echo "  --help      Show this help"
            echo ""
            echo "WARNING: --volumes and --purge will permanently delete all"
            echo "         SHOG data including Wazuh logs, Pi-hole config, and"
            echo "         all collected security telemetry. This cannot be undone."
            exit 0 ;;
        *)
            echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ============================================================================
# WARNING BANNER
# ============================================================================
echo -e "${RED}${BOLD}"
cat <<'WARN'
 _    _      _ _         __      __       _    _
| |  | |    | | |        \ \    / /      | |  (_)
| |__| | ___| | | ___     \ \  / /__ _ __| | ___ _ __   ___ _ __
|  __  |/ _ \ | |/ _ \     \ \/ / _ \ '__| |/ / | '_ \ / _ \ '__|
| |  | |  __/ | | (_) |     \  /  __/ |  |   <| | | | |  __/ |
|_|  |_|\___|_|_|\___/       \/ \___|_|  |_|\_\_|_| |_|\___|_|
WARN
echo -e "${NC}"

if [[ "$DELETE_VOLUMES" == true || "$PURGE" == true ]]; then
    echo -e "${RED}${BOLD}WARNING: You have requested volume deletion.${NC}"
    echo -e "${RED}This will PERMANENTLY erase all SHOG data including:${NC}"
    echo "  - Wazuh security logs and alerts"
    echo "  - Pi-hole DNS configuration and blocklists"
    echo "  - CrowdSec threat intelligence data"
    echo "  - Portainer settings"
    echo "  - Uptime Kuma monitor configuration"
    echo "  - OpenCTI threat intelligence (if enabled)"
    echo ""
fi

if [[ "$PURGE" == true ]]; then
    echo -e "${RED}${BOLD}PURGE MODE: All configuration files, .env secrets, logs, and backups${NC}"
    echo -e "${RED}will also be deleted. This is IRREVERSIBLE.${NC}"
    echo ""
fi

# ============================================================================
# CONFIRMATION
# ============================================================================
if [[ "$SKIP_CONFIRM" == false ]]; then
    echo -e "${BOLD}This will stop and remove all SHOG containers.${NC}"
    echo ""
    read -rp "Type 'uninstall' to proceed: " CONFIRM
    if [[ "$CONFIRM" != "uninstall" ]]; then
        echo -e "${YELLOW}Uninstall cancelled.${NC}"
        exit 0
    fi

    if [[ "$DELETE_VOLUMES" == true ]]; then
        echo ""
        echo -e "${RED}${BOLD}FINAL WARNING: About to delete all SHOG data volumes.${NC}"
        read -rp "Type 'DELETE ALL DATA' to confirm permanent data deletion: " CONFIRM2
        if [[ "$CONFIRM2" != "DELETE ALL DATA" ]]; then
            echo -e "${YELLOW}Data deletion cancelled. Containers will be stopped but volumes kept.${NC}"
            DELETE_VOLUMES=false
            PURGE=false
        fi
    fi
fi

# ============================================================================
# STOP AND REMOVE CONTAINERS
# ============================================================================
echo ""
echo -e "${BOLD}Stopping SHOG containers...${NC}"
docker compose down --remove-orphans

if [[ $? -eq 0 ]]; then
    echo -e "${GREEN}All containers stopped and removed.${NC}"
else
    echo -e "${YELLOW}Some containers may not have been removed cleanly.${NC}"
fi

# ============================================================================
# REMOVE VOLUMES
# ============================================================================
if [[ "$DELETE_VOLUMES" == true ]]; then
    echo ""
    echo -e "${BOLD}Deleting named volumes...${NC}"

    VOLUMES=(
        "shog-unbound-data"
        "shog-pihole-etc"
        "shog-pihole-dnsmasq"
        "shog-rsyslog-data"
        "shog-rsyslog-spool"
        "shog-crowdsec-config"
        "shog-crowdsec-data"
        "shog-crowdsec-bouncer-data"
        "shog-crowdsec-bouncer-logs"
        "shog-wazuh-indexer-data"
        "shog-wazuh-manager-var-ossec"
        "shog-wazuh-manager-etc"
        "shog-wazuh-dashboard-data"
        "shog-wazuh-agent-var-ossec"
        "shog-filebeat-data"
        "shog-filebeat-logs"
        "shog-portainer-data"
        "shog-uptime-kuma-data"
        "shog-alerting-data"
        "shog-opencti-data"
        "shog-opencti-redis-data"
        "shog-opencti-es-data"
        "shog-opencti-minio-data"
        "shog-opencti-rabbitmq-data"
    )

    for vol in "${VOLUMES[@]}"; do
        if docker volume inspect "$vol" &>/dev/null; then
            docker volume rm "$vol" 2>/dev/null && echo "  Deleted: $vol" || echo "  Failed:  $vol"
        fi
    done

    echo -e "${GREEN}Volume deletion complete.${NC}"
fi

# ============================================================================
# REMOVE IMAGES
# ============================================================================
if [[ "$DELETE_IMAGES" == true ]]; then
    echo ""
    echo -e "${BOLD}Removing SHOG container images...${NC}"

    IMAGES=(
        "mvance/unbound"
        "pihole/pihole"
        "rsyslog/syslog_appliance_alpine"
        "crowdsecurity/crowdsec"
        "crowdsecurity/iptables-bouncer"
        "wazuh/wazuh-indexer"
        "wazuh/wazuh-manager"
        "wazuh/wazuh-dashboard"
        "wazuh/wazuh-agent"
        "portainer/portainer-ce"
        "louislam/uptime-kuma"
        "docker.elastic.co/beats/filebeat-oss"
        "ghcr.io/containrrr/shoutrrr"
        "opencti/platform"
        "redis"
        "docker.elastic.co/elasticsearch/elasticsearch"
        "minio/minio"
        "rabbitmq"
        "opencti/connector-mitre"
        "alpine"
    )

    for img in "${IMAGES[@]}"; do
        # Find and remove images matching our prefix
        docker images --format "{{.Repository}}:{{.Tag}}" | grep "^${img}:" | while read -r img_full; do
            docker rmi "$img_full" 2>/dev/null && echo "  Removed: $img_full" || true
        done
    done

    echo -e "${GREEN}Image removal complete.${NC}"
fi

# ============================================================================
# PURGE MODE: Remove configs, .env, logs, backups
# ============================================================================
if [[ "$PURGE" == true ]]; then
    echo ""
    echo -e "${RED}${BOLD}PURGING configuration files and local data...${NC}"

    [[ -f ".env" ]] && rm -f ".env" && echo "  Removed: .env"
    [[ -d "logs" ]] && rm -rf "logs" && echo "  Removed: logs/"
    [[ -d "backups" ]] && rm -rf "backups" && echo "  Removed: backups/"
    [[ -f "compose.override.yml" ]] && rm -f "compose.override.yml" && echo "  Removed: compose.override.yml"

    echo -e "${RED}Purge complete. The repository directory remains with source configs.${NC}"
fi

# ============================================================================
# SUMMARY
# ============================================================================
echo ""
echo -e "${GREEN}${BOLD}SHOG uninstallation complete.${NC}"
echo ""

if [[ "$DELETE_VOLUMES" == false && "$PURGE" == false ]]; then
    echo -e "${YELLOW}Docker volumes were preserved.${NC}"
    echo "To remove volumes later: ./uninstall.sh --volumes --yes"
    echo ""
    echo "Your data is safe. To redeploy:"
    echo "  ./install.sh"
fi

echo ""
echo -e "${BOLD}Note: This script does NOT modify your pfSense firewall.${NC}"
echo "      pfSense configuration must be reverted manually if desired."
