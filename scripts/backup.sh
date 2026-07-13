#!/usr/bin/env bash
# =============================================================================
# SHOG Backup Script
# Creates timestamped backups of all persistent data.
# =============================================================================
# Usage: ./scripts/backup.sh [options]
#   --destination <path>  Backup directory (default: ./backups)
#   --volumes-only        Only backup Docker volumes
#   --configs-only        Only backup configuration files
#   --retention <days>    Delete backups older than N days (default: 30)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Defaults
DESTINATION="$PROJECT_DIR/backups"
BACKUP_VOLUMES=true
BACKUP_CONFIGS=true
RETENTION_DAYS=30

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# --- Parse arguments ---------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --destination)
            shift; DESTINATION="$1"; shift ;;
        --volumes-only)
            BACKUP_CONFIGS=false; shift ;;
        --configs-only)
            BACKUP_VOLUMES=false; shift ;;
        --retention)
            shift; RETENTION_DAYS="$1"; shift ;;
        --help|-h)
            echo "Usage: ./scripts/backup.sh [options]"
            echo ""
            echo "Options:"
            echo "  --destination <path>  Backup directory (default: ./backups)"
            echo "  --volumes-only        Only backup Docker volumes"
            echo "  --configs-only        Only backup configuration files"
            echo "  --retention <days>    Delete backups older than N days (default: 30)"
            echo "  --help, -h            Show this help"
            exit 0 ;;
        *)
            log_error "Unknown option: $1"; exit 1 ;;
    esac
done

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="$DESTINATION/shog-backup-$TIMESTAMP"
LOG_FILE="$BACKUP_DIR/backup.log"

mkdir -p "$BACKUP_DIR"
touch "$LOG_FILE"

log_info()  { echo -e "${BLUE}[INFO]${NC}  $1" | tee -a "$LOG_FILE"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $1" | tee -a "$LOG_FILE"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1" | tee -a "$LOG_FILE"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"; }

log_info "Starting SHOG backup..."
log_info "Backup directory: $BACKUP_DIR"
log_info "Timestamp: $TIMESTAMP"

# ============================================================================
# 1. BACKUP CONFIGURATION FILES
# ============================================================================
if [[ "$BACKUP_CONFIGS" == true ]]; then
    log_info "Backing up configuration files..."

    mkdir -p "$BACKUP_DIR/configs"

    # .env (secrets file)
    if [[ -f "$PROJECT_DIR/.env" ]]; then
        cp "$PROJECT_DIR/.env" "$BACKUP_DIR/configs/env.backup"
        chmod 600 "$BACKUP_DIR/configs/env.backup"
        log_ok ".env backed up"
    fi

    # Service configurations
    if [[ -d "$PROJECT_DIR/configs" ]]; then
        cp -r "$PROJECT_DIR/configs" "$BACKUP_DIR/configs/"
        log_ok "Service configs backed up"
    fi

    # Docker Compose files
    if [[ -f "$PROJECT_DIR/docker-compose.yml" ]]; then
        cp "$PROJECT_DIR/docker-compose.yml" "$BACKUP_DIR/configs/"
    fi
    if [[ -f "$PROJECT_DIR/compose.override.yml" ]]; then
        cp "$PROJECT_DIR/compose.override.yml" "$BACKUP_DIR/configs/"
    fi

    # Installer scripts
    cp "$PROJECT_DIR/install.sh" "$BACKUP_DIR/configs/" 2>/dev/null || true
    cp -r "$PROJECT_DIR/scripts" "$BACKUP_DIR/configs/" 2>/dev/null || true

    log_ok "Configuration backup complete"
fi

# ============================================================================
# 2. BACKUP DOCKER VOLUMES
# ============================================================================
if [[ "$BACKUP_VOLUMES" == true ]]; then
    log_info "Backing up Docker volumes..."

    cd "$PROJECT_DIR"

    # List of named volumes to backup
    VOLUMES=(
        "shog-unbound-data:unbound"
        "shog-pihole-etc:pihole-etc"
        "shog-pihole-dnsmasq:pihole-dnsmasq"
        "shog-rsyslog-data:rsyslog-data"
        "shog-rsyslog-spool:rsyslog-spool"
        "shog-crowdsec-config:crowdsec-config"
        "shog-crowdsec-data:crowdsec-data"
        "shog-wazuh-indexer-data:wazuh-indexer"
        "shog-wazuh-manager-var-ossec:wazuh-manager"
        "shog-wazuh-dashboard-data:wazuh-dashboard"
        "shog-wazuh-agent-var-ossec:wazuh-agent"
        "shog-portainer-data:portainer"
        "shog-uptime-kuma-data:uptime-kuma"
    )

    # Optional: OpenCTI volumes if they exist
    OPENCTI_VOLUMES=(
        "shog-opencti-data:opencti"
        "shog-opencti-redis-data:opencti-redis"
        "shog-opencti-es-data:opencti-elasticsearch"
        "shog-opencti-minio-data:opencti-minio"
        "shog-opencti-rabbitmq-data:opencti-rabbitmq"
    )

    # Check if OpenCTI volumes exist and add them
    for vol_info in "${OPENCTI_VOLUMES[@]}"; do
        vol_name="${vol_info%%:*}"
        if docker volume inspect "$vol_name" &>/dev/null; then
            V+=("$vol_info")
        fi
    done

    FAILED_VOLUMES=0

    for vol_info in "${VOLUMES[@]}" "${V[@]+"${V[@]}"}"; do
        vol_name="${vol_info%%:*}"
        backup_label="${vol_info##*:}"
        backup_file="$BACKUP_DIR/${backup_label}-${TIMESTAMP}.tar.gz"

        if docker volume inspect "$vol_name" &>/dev/null; then
            log_info "  Backing up $vol_name ..."

            # Use a temporary container to tar the volume
            if docker run --rm \
                -v "$vol_name:/volume:ro" \
                -v "$BACKUP_DIR:/backup" \
                alpine:3.19 \
                sh -c "cd /volume && tar czf /backup/${backup_label}-${TIMESTAMP}.tar.gz ." 2>> "$LOG_FILE"; then

                # Verify backup
                if [[ -f "$backup_file" && -s "$backup_file" ]]; then
                    SIZE=$(du -h "$backup_file" | cut -f1)
                    log_ok "  $vol_name -> ${backup_label}-${TIMESTAMP}.tar.gz ($SIZE)"
                else
                    log_error "  $vol_name backup file is empty or missing"
                    ((FAILED_VOLUMES++))
                fi
            else
                log_error "  Failed to backup $vol_name"
                ((FAILED_VOLUMES++))
            fi
        else
            log_warn "  Volume $vol_name does not exist — skipping"
        fi
    done

    if [[ $FAILED_VOLUMES -gt 0 ]]; then
        log_warn "$FAILED_VOLUMES volume(s) failed to backup"
    else
        log_ok "All Docker volumes backed up"
    fi
fi

# ============================================================================
# 3. BACKUP METADATA
# ============================================================================
{
    echo "SHOG Backup Metadata"
    echo "===================="
    echo "Timestamp:    $TIMESTAMP"
    echo "Host:         $(hostname)"
    echo "User:         $(whoami)"
    echo "Docker:       $(docker --version)"
    echo "Compose:      $(docker compose version --short)"
    echo "Backup Type:  $([[ $BACKUP_VOLUMES == true ]] && echo volumes) $([[ $BACKUP_CONFIGS == true ]] && echo configs)"
    echo ""
    echo "Running Containers:"
    docker compose ps --format "table {{.Name}}\t{{.State}}\t{{.Health}}" 2>/dev/null || true
    echo ""
    echo "Disk Usage:"
    df -h "$PROJECT_DIR" 2>/dev/null || true
} >> "$BACKUP_DIR/backup-metadata.txt"

log_ok "Backup metadata written"

# ============================================================================
# 4. CLEANUP OLD BACKUPS
# ============================================================================
if [[ "$RETENTION_DAYS" -gt 0 ]]; then
    log_info "Cleaning up backups older than $RETENTION_DAYS days..."
    DELETED=$(find "$DESTINATION" -maxdepth 1 -type d -name 'shog-backup-*' -mtime +$RETENTION_DAYS | wc -l)
    find "$DESTINATION" -maxdepth 1 -type d -name 'shog-backup-*' -mtime +$RETENTION_DAYS -exec rm -rf {} + 2>/dev/null || true
    log_ok "Deleted $DELETED old backup(s)"
fi

# ============================================================================
# 5. SUMMARY
# ============================================================================
BACKUP_SIZE=$(du -sh "$BACKUP_DIR" | cut -f1)
log_ok "Backup complete: $BACKUP_DIR ($BACKUP_SIZE)"
log_info "To restore, see: docs/restore.md"

# Create latest symlink
ln -sfn "$BACKUP_DIR" "$DESTINATION/shog-backup-latest"
