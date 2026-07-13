# SHOG Troubleshooting Guide

## Quick Diagnostics

Run the health check first:
```bash
./scripts/health-check.sh
```

For continuous monitoring:
```bash
./scripts/health-check.sh --watch
```

---

## Installation Issues

### Preflight Check Failures

**Problem**: `vm.max_map_count is too low`
```bash
# Fix:
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-shog.conf
sudo sysctl --system
```

**Problem**: Port 53 already in use (systemd-resolved)
```bash
# Fix:
sudo systemctl disable --now systemd-resolved
sudo rm -f /etc/resolv.conf
echo "nameserver 1.1.1.1" | sudo tee /etc/resolv.conf
```

**Problem**: Docker not installed or not running
```bash
# Install Docker (Ubuntu):
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
newgrp docker
```

**Problem**: Docker Compose plugin missing
```bash
sudo apt install docker-compose-plugin
```

---

## Service Startup Issues

### Wazuh Indexer fails to start

**Symptoms**: `docker logs shog-wazuh-indexer` shows memory or permission errors.

**Checks**:
```bash
# 1. Check vm.max_map_count
sysctl vm.max_map_count  # Must be >= 262144

# 2. Check available memory
free -h

# 3. Check volume permissions
docker volume inspect shog-wazuh-indexer-data

# 4. Check logs
docker logs --tail 100 shog-wazuh-indexer
```

**Fixes**:
- Increase `vm.max_map_count` (see above)
- Reduce `WAZUH_INDEXER_HEAP` in `.env` if RAM is limited
- Delete volume and restart (data loss — use backup): `docker volume rm shog-wazuh-indexer-data`

### Wazuh Dashboard shows "Wazuh API seems to be down"

**Symptoms**: Dashboard loads but shows API connection error.

**Checks**:
```bash
# 1. Verify manager is running
docker ps | grep wazuh-manager

# 2. Check manager health
docker exec shog-wazuh-manager /var/ossec/bin/wazuh-control status

# 3. Check API credentials match
grep WAZUH_API_PASSWORD .env

# 4. Test API directly from dashboard container
docker exec shog-wazuh-dashboard curl -k -u wazuh-wui:$(grep WAZUH_API_PASSWORD .env | cut -d= -f2) \
  https://wazuh-manager:55000/security/user/authenticate
```

**Fixes**:
- Wait 2-3 minutes after startup for full initialization
- Ensure `.env` passwords match across services
- Restart stack: `docker compose restart`

### Pi-hole DNS not responding

**Symptoms**: DNS queries timeout; `dig @<pi-hole-ip> google.com` fails.

**Checks**:
```bash
# 1. Check container
docker ps | grep pihole
docker logs shog-pihole --tail 50

# 2. Test Unbound directly
dig @127.0.0.1 -p 5335 google.com

# 3. Check if port 53 is free on host
sudo ss -tlnp | grep :53

# 4. Check Pi-hole config
docker exec shog-pihole pihole status
```

**Fixes**:
- Ensure systemd-resolved is disabled (see above)
- Restart Pi-hole: `docker restart shog-pihole`
- Check if Unbound is healthy (Pi-hole depends on it)
- Verify `PIHOLE_DNS_` in `.env` points to Unbound IP

### CrowdSec bouncer not working

**Symptoms**: IPs not being blocked despite decisions.

**Checks**:
```bash
# 1. Check bouncer registration
docker exec shog-crowdsec cscli bouncers list

# 2. Check decisions
docker exec shog-crowdsec cscli decisions list

# 3. Check bouncer logs
docker logs shog-crowdsec-bouncer 2>/dev/null || echo "Bouncer not running"

# 4. Check iptables on host
sudo iptables -L DOCKER-USER -n --line-numbers
```

**Fixes**:
- Ensure `CROWDSEC_BOUNCER_KEY` in `.env` matches registered bouncer
- Enable host-bouncer profile: `docker compose --profile host-bouncer up -d`
- Register bouncer manually: `docker exec shog-crowdsec cscli bouncers add shog-bouncer`

---

## Network Issues

### Cannot access admin UIs from management VLAN

**Symptoms**: Connection refused or timeout to Portainer/Wazuh/Uptime Kuma.

**Checks**:
```bash
# 1. Verify MANAGEMENT_IP in .env
grep MANAGEMENT_IP .env

# 2. Check what's listening on host
sudo ss -tlnp | grep -E '9443|5601|3001|8080'

# 3. Check Docker port bindings
docker ps --format "table {{.Names}}\t{{.Ports}}" | grep shog

# 4. Test from Docker host itself
curl -k https://127.0.0.1:9443/api/status
curl -k https://127.0.0.1:5601
```

**Fixes**:
- If `MANAGEMENT_IP=127.0.0.1`: Only accessible from Docker host itself. Use SSH tunnel:
  ```bash
  ssh -L 9443:localhost:9443 -L 5601:localhost:5601 admin@docker-host
  ```
- If `MANAGEMENT_IP=192.168.10.x`: Ensure client is on Management VLAN
- Check pfSense firewall rules allow Management VLAN to Docker host

### pfSense not forwarding syslog

**Symptoms**: No logs in `/var/log/remote/` inside rsyslog container.

**Checks**:
```bash
# 1. Check rsyslog is listening
docker exec shog-rsyslog ss -tlnp | grep 514

# 2. Check remote log directory
docker exec shog-rsyslog ls -la /var/log/remote/

# 3. Test from pfSense shell
# ssh to pfSense, then:
logger -n 192.168.40.10 -P 514 "test from pfsense"

# 4. Check rsyslog logs
docker logs shog-rsyslog --tail 50
```

**Fixes**:
- Verify pfSense Status > System Logs > Settings has remote logging enabled
- Check pfSense can reach Docker host: `ping 192.168.40.10` from pfSense
- Verify firewall rule allows UDP 514 from pfSense to Docker host
- Restart rsyslog: `docker restart shog-rsyslog`

### Suricata alerts not appearing in Wazuh

**Symptoms**: Suricata running on pfSense but no alerts in Wazuh Dashboard.

**Checks**:
```bash
# 1. Check EVE JSON file exists on pfSense
# SSH to pfSense:
cat /var/log/suricata/suricata_*/eve.json | tail -5

# 2. Check rsyslog has Suricata logs
docker exec shog-rsyslog find /var/log/remote -name "suricata*" -type f

# 3. Check Filebeat is shipping
docker logs shog-filebeat --tail 50

# 4. Check Wazuh indices
curl -k -u admin:$(grep WAZUH_INDEXER_PASSWORD .env | cut -d= -f2) \
  https://localhost:9200/_cat/indices | grep wazuh-alerts-suricata
```

**Fixes**:
- Ensure Suricata EVE output is in single-line JSON format (not pretty-printed)
- Verify Filebeat can read rsyslog data volume
- Check `.env` has correct `WAZUH_INDEXER_PASSWORD`
- Manually trigger test alert:
  ```bash
  # From any LAN client:
  curl -s http://testmynids.org/uid/index.html
  ```

---

## Performance Issues

### High CPU usage

```bash
# Identify culprit
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}"

# Common causes:
# - Wazuh indexer with too many shards
# - Suricata in IPS mode on underpowered pfSense
# - CrowdSec parsing large log files
```

**Fixes**:
- Reduce `WAZUH_INDEXER_HEAP` in `.env`
- Enable CrowdSec ` acquisition` limits in `acquis.yaml`
- Consider adding CPU limits in `compose.override.yml`

### High disk usage

```bash
# Check volume sizes
docker system df -v

# Check log sizes
sudo du -sh /var/lib/docker/containers/*

# Check Pi-hole database
docker exec shog-pihole ls -lh /etc/pihole/*.db
```

**Fixes**:
- Run log rotation: `docker system prune --volumes` (WARNING: removes unused volumes)
- Reduce Pi-hole `FTLCONF_MAXDBDAYS` in `.env`
- Enable automated cleanup cron job

### Slow Wazuh Dashboard queries

**Fixes**:
- Increase `WAZUH_INDEXER_HEAP` to 2g or 4g if RAM available
- Reduce index retention (Wazuh Index Management)
- Close old indices:
  ```bash
  curl -k -u admin:password https://localhost:9200/_cat/indices | grep wazuh-alerts
  # Close indices older than 30 days
  ```

---

## Common Error Messages

| Error | Cause | Solution |
|-------|-------|----------|
| `Connection refused` to service | Container not running or not ready | `docker ps`, check health status |
| `bind: address already in use` | Port conflict | Find and stop conflicting service |
| `max virtual memory areas vm.max_map_count` | Kernel limit too low | Set `vm.max_map_count=262144` |
| `Permission denied` on volume | Wrong permissions | `chown` or recreate volume |
| `API authentication failed` | Wrong password in `.env` | Regenerate or check `.env` |
| `no space left on device` | Disk full | Free disk space, prune Docker |
| `network not found` | Docker network missing | `docker compose up` recreates it |

---

## Recovery Procedures

### Complete stack restart

```bash
# Graceful restart
docker compose down
docker compose up -d

# If issues persist — force recreation:
docker compose down
docker compose pull
docker compose up -d --force-recreate
```

### Reset single service (keep data)

```bash
# Example: Reset Pi-hole while keeping config
docker compose stop pihole
docker compose rm pihole
docker compose up -d pihole
```

### Reset single service (lose data)

```bash
# Example: Reset Wazuh indexer (COMPLETE DATA LOSS)
docker compose stop wazuh-indexer
docker volume rm shog-wazuh-indexer-data
docker compose up -d wazuh-indexer
```

### View all logs

```bash
# All services
docker compose logs --tail 100

# Specific service
docker compose logs -f wazuh-manager

# Since specific time
docker compose logs --since 30m
```

---

## Getting Help

1. Check this troubleshooting guide
2. Run `./scripts/health-check.sh --json` for structured diagnostics
3. Review service logs: `docker compose logs <service>`
4. Check Wazuh documentation: https://documentation.wazuh.com/
5. Check pfSense documentation: https://docs.netgate.com/
6. Open an issue with: `.env` (redact passwords), `docker ps` output, relevant logs
