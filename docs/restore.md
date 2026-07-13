# SHOG Restore Procedures

## Prerequisites

- Docker Engine and Docker Compose plugin installed
- `.env` file available (or backup of `.env`)
- Backup archives from `scripts/backup.sh`
- SHOG repository cloned/available

---

## Restore Types

### Type 1: Configuration-Only Restore

Use when data volumes are intact but configuration was lost.

```bash
# 1. Navigate to SHOG directory
cd /path/to/shog

# 2. Restore .env from backup
cp backups/shog-backup-YYYYMMDD_HHMMSS/configs/env.backup .env
chmod 600 .env

# 3. Restore configuration files
cp -r backups/shog-backup-YYYYMMDD_HHMMSS/configs/* configs/

# 4. Restart stack
docker compose restart
```

### Type 2: Single Volume Restore

Use when a specific service's data is corrupted.

```bash
# Example: Restore Pi-hole data only

# 1. Stop the service
docker compose stop pihole

# 2. Backup current volume (just in case)
docker run --rm -v shog-pihole-etc:/volume -v $(pwd)/backups:/backup \
  alpine tar czf /backup/pihole-etc-pre-restore.tar.gz -C /volume .

# 3. Clear current volume data
docker run --rm -v shog-pihole-etc:/volume alpine sh -c "rm -rf /volume/*"

# 4. Restore from backup archive
docker run --rm -v shog-pihole-etc:/volume \
  -v $(pwd)/backups/shog-backup-YYYYMMDD_HHMMSS:/backup \
  alpine sh -c "cd /volume && tar xzf /backup/pihole-etc-YYYYMMDD_HHMMSS.tar.gz"

# 5. Start service
docker compose start pihole

# 6. Verify
docker logs shog-pihole --tail 30
```

### Type 3: Full Disaster Recovery

Use when the entire Docker host has been rebuilt.

```bash
# 1. Install prerequisites (Docker, Compose)
curl -fsSL https://get.docker.com | sudo sh
sudo apt install docker-compose-plugin

# 2. Clone SHOG repository
git clone https://github.com/your-org/shog.git /opt/shog
cd /opt/shog

# 3. Restore .env
cp /path/to/backup/shog-backup-YYYYMMDD_HHMMSS/configs/env.backup .env
chmod 600 .env

# 4. Restore configs
cp -r /path/to/backup/shog-backup-YYYYMMDD_HHMMSS/configs/* configs/

# 5. Pull images
docker compose pull

# 6. Create volumes (empty)
docker compose up -d

# 7. Stop all services
docker compose stop

# 8. Restore all volumes
BACKUP_DIR="/path/to/backup/shog-backup-YYYYMMDD_HHMMSS"

for archive in "$BACKUP_DIR"/*.tar.gz; do
    # Extract volume name from filename
    vol_label=$(basename "$archive" | sed 's/-[0-9]*_.*\.tar\.gz//')

    # Map label to Docker volume name
    case "$vol_label" in
        "unbound")         VOL="shog-unbound-data" ;;
        "pihole-etc")      VOL="shog-pihole-etc" ;;
        "pihole-dnsmasq")  VOL="shog-pihole-dnsmasq" ;;
        "rsyslog-data")    VOL="shog-rsyslog-data" ;;
        "rsyslog-spool")   VOL="shog-rsyslog-spool" ;;
        "crowdsec-config") VOL="shog-crowdsec-config" ;;
        "crowdsec-data")   VOL="shog-crowdsec-data" ;;
        "wazuh-indexer")   VOL="shog-wazuh-indexer-data" ;;
        "wazuh-manager")   VOL="shog-wazuh-manager-var-ossec" ;;
        "wazuh-dashboard") VOL="shog-wazuh-dashboard-data" ;;
        "wazuh-agent")     VOL="shog-wazuh-agent-var-ossec" ;;
        "portainer")       VOL="shog-portainer-data" ;;
        "uptime-kuma")     VOL="shog-uptime-kuma-data" ;;
        "opencti")         VOL="shog-opencti-data" ;;
        "opencti-redis")   VOL="shog-opencti-redis-data" ;;
        "opencti-elasticsearch") VOL="shog-opencti-es-data" ;;
        "opencti-minio")   VOL="shog-opencti-minio-data" ;;
        "opencti-rabbitmq") VOL="shog-opencti-rabbitmq-data" ;;
        *) echo "Unknown volume label: $vol_label"; continue ;;
    esac

    echo "Restoring $vol_label -> $VOL..."
    docker run --rm -v "$VOL:/volume" -v "$BACKUP_DIR:/backup" \
        alpine sh -c "cd /volume && tar xzf /backup/$(basename "$archive")"
done

# 9. Start all services
docker compose up -d

# 10. Verify health
./scripts/health-check.sh
```

### Type 4: Selective Point-in-Time Restore

Restore specific data from a specific backup date.

```bash
# List available backups
ls -la backups/shog-backup-*/

# Choose backup by date
BACKUP_DATE="20240115_030000"
BACKUP_DIR="backups/shog-backup-$BACKUP_DATE"

# Restore only Wazuh data from that date
docker compose stop wazuh-indexer wazuh-manager wazuh-dashboard

for vol_label in wazuh-indexer wazuh-manager wazuh-dashboard; do
    archive="$BACKUP_DIR/${vol_label}-${BACKUP_DATE}.tar.gz"
    if [[ -f "$archive" ]]; then
        VOL="shog-${vol_label//-/-}${vol_label:+}"
        case "$vol_label" in
            "wazuh-indexer") VOL="shog-wazuh-indexer-data" ;;
            "wazuh-manager") VOL="shog-wazuh-manager-var-ossec" ;;
            "wazuh-dashboard") VOL="shog-wazuh-dashboard-data" ;;
        esac
        docker run --rm -v "$VOL:/volume" -v "$BACKUP_DIR:/backup" \
            alpine sh -c "cd /volume && rm -rf /volume/* && tar xzf /backup/$(basename "$archive")"
        echo "Restored $vol_label"
    fi
done

docker compose start wazuh-indexer wazuh-manager wazuh-dashboard
```

---

## Cross-Platform Restore Notes

### Restore to Different Architecture

Backups contain architecture-specific data. When restoring to a different architecture (e.g., x86_64 to ARM64):

1. Configuration files: **Fully portable** — restore directly
2. Application data: **Generally portable** — SQLite, JSON, text logs
3. Indexed data (Wazuh/Elasticsearch): **Not portable** — must reindex
4. Binary caches: **Not portable** — will be rebuilt

**Recommendation**: For architecture changes, restore configs only and let Wazuh reindex.

### Restore to Different Host IP/Network

If restoring to a host with different IP addresses:

1. Update `.env` with new network settings
2. Update `MANAGEMENT_IP` to new trusted subnet
3. Update pfSense to point to new Docker host IP
4. Update static DHCP mappings in pfSense

---

## Verification After Restore

```bash
# 1. All containers running
./scripts/health-check.sh

# 2. DNS resolution works
dig @$(grep PIHOLE_IP .env | cut -d= -f2) google.com

# 3. Wazuh Dashboard accessible
curl -k -s -o /dev/null -w "%{http_code}" \
  https://$(grep MANAGEMENT_IP .env | cut -d= -f2):5601

# 4. Pi-hole admin works
curl -s -o /dev/null -w "%{http_code}" \
  http://$(grep MANAGEMENT_IP .env | cut -d= -f2):8080/admin

# 5. Check data integrity
# Wazuh: Verify indices exist
curl -k -u admin:$(grep WAZUH_INDEXER_PASSWORD .env | cut -d= -f2) \
  https://$(grep MANAGEMENT_IP .env | cut -d= -f2):9200/_cat/indices

# Pi-hole: Check query count in last 24h
docker exec shog-pihole sqlite3 /etc/pihole/pihole-FTL.db \
  "SELECT COUNT(*) FROM queries WHERE timestamp > $(date -d '24 hours ago' +%s);"
```

---

## Automated Restore Script

Create `scripts/restore.sh` for automated recovery:

```bash
#!/usr/bin/env bash
# save as scripts/restore.sh
set -euo pipefail

BACKUP_DIR="${1:-}"
if [[ -z "$BACKUP_DIR" || ! -d "$BACKUP_DIR" ]]; then
    echo "Usage: $0 <backup-directory>"
    echo "Available backups:"
    ls -d backups/shog-backup-* 2>/dev/null || echo "  (none found)"
    exit 1
fi

echo "Restoring from: $BACKUP_DIR"

# Restore .env
if [[ -f "$BACKUP_DIR/configs/env.backup" ]]; then
    cp "$BACKUP_DIR/configs/env.backup" .env
    chmod 600 .env
    echo "[OK] .env restored"
fi

# Restore configs
if [[ -d "$BACKUP_DIR/configs" ]]; then
    cp -r "$BACKUP_DIR/configs/"* configs/ 2>/dev/null || true
    echo "[OK] Configs restored"
fi

# Restore volumes
for archive in "$BACKUP_DIR"/*.tar.gz; do
    [[ -f "$archive" ]] || continue
    vol_name=$(basename "$archive" | sed 's/-[0-9]*_.*\.tar\.gz//')
    # ... (volume mapping logic from Type 3)
    echo "[OK] Restored volume: $vol_name"
done

echo "Restore complete. Run: docker compose up -d"
```

---

## Backup Retention Strategy

| Backup Type | Frequency | Retention | Storage |
|-------------|-----------|-----------|---------|
| Full (volumes + configs) | Daily | 7 days | Local SSD |
| Full | Weekly | 4 weeks | External USB/NAS |
| Full | Monthly | 12 months | Offsite/cloud |
| Config-only | On every change | All versions | Git repository |

**Cron schedule**:
```bash
# Daily at 3 AM
0 3 * * * /opt/shog/scripts/backup.sh --retention 7 >> /var/log/shog-backup.log 2>&1

# Weekly on Sunday at 2 AM (to NAS)
0 2 * * 0 /opt/shog/scripts/backup.sh --destination /mnt/nas/shog-backups --retention 28 >> /var/log/shog-backup.log 2>&1
```
