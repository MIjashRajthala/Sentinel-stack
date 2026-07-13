# SHOG Evaluation Plan

## 1. Deployment Metrics

### 1.1 Deployment Time

| Phase | Target | Measurement Method |
|-------|--------|-------------------|
| Preflight checks | < 30 seconds | `time scripts/preflight-check.sh` |
| Secret generation | < 10 seconds | `time scripts/generate-secrets.sh` |
| Image pull (core stack) | < 10 minutes | `time docker compose pull` (first run) |
| Stack startup | < 5 minutes | `time docker compose up -d` |
| **Total one-command deploy** | **< 20 minutes** | `time ./install.sh` |
| Post-install pfSense config | 30-60 minutes | Manual steps timed |

### 1.2 Manual Configuration Steps

| Step | Count | Automated? |
|------|-------|------------|
| Run install.sh | 1 | Yes |
| Edit .env if needed | 0-3 | Semi (template provided) |
| pfSense WAN setup | 1 | No (manual) |
| pfSense LAN + DHCP | 1 | No (manual) |
| VLAN creation (3 VLANs) | 3 | No (manual) |
| Firewall rules per VLAN | ~12 rules | No (manual) |
| DNS configuration | 1 | No (manual) |
| Suricata setup | 1 | No (manual) |
| Syslog forwarding | 1 | No (manual) |
| WireGuard VPN | 1 | No (manual) |
| Admin access restriction | 1 | No (manual) |
| **Total manual steps** | **~23 discrete actions** | |

**Goal**: All pfSense steps documented with exact UI navigation paths. Docker-side fully automated.

---

## 2. Benign Attack Simulations (Testing Plan)

### Test 1: Nmap Port Scan

**Objective**: Verify Suricata detects and logs port scanning activity.

```bash
# From a client on the LAN:
nmap -sS -p 1-1000 -T4 192.168.40.10
nmap -sV -sC -O 192.168.40.10  # More aggressive scan
```

**Expected Results**:
- [ ] Suricata generates ET SCAN alerts in EVE JSON
- [ ] Alerts visible in Wazuh Dashboard within 60 seconds
- [ ] pfSense filterlog shows blocked/rejected connection attempts
- [ ] CrowdSec may flag source IP (if aggressive enough)

**Evidence**: Screenshot of Wazuh alert; Suricata EVE JSON entry.

---

### Test 2: Repeated Failed SSH Login

**Objective**: Verify CrowdSec and Wazuh detect brute-force attempts.

```bash
# From a client or external host:
for i in {1..15}; do
    ssh -o BatchMode=yes admin@192.168.40.10 "exit" 2>/dev/null
done

# Or use hydra for controlled testing:
hydra -l admin -p wrongpassword 192.168.40.10 ssh -t 4
```

**Expected Results**:
- [ ] Wazuh rule 5712 fires (sshd: brute force attempt)
- [ ] CrowdSec triggers decision on source IP within 5 minutes
- [ ] If host-bouncer profile enabled: IP blocked via iptables
- [ ] Alert visible in both CrowdSec (cscli decisions list) and Wazuh

**Evidence**: `cscli decisions list` output; Wazuh alert screenshot.

**Cleanup**: `cscli decisions delete --ip <test-ip>`

---

### Test 3: Malicious DNS Domain Query

**Objective**: Verify Pi-hole blocks known malicious domains and logs the attempt.

```bash
# From a LAN client (must use Pi-hole as DNS):
dig @192.168.40.10 malware.testcategory.com
dig @192.168.40.10 doubleclick.net
# Or use Pi-hole's built-in test:
dig @192.168.40.10 pi.hole

# Query a known test domain (if Pi-hole default lists loaded):
dig @192.168.40.10 tracker.example
```

**Alternative**: Use Pi-hole's built-in blocklist test domain or add a custom blocklist entry:
```
Pi-hole admin > Adlists > Add: https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts
```

**Expected Results**:
- [ ] Blocked domain returns 0.0.0.0 or NXDOMAIN
- [ ] Query appears in Pi-hole Query Log
- [ ] If Wazuh Pi-hole integration configured: alert in Wazuh

**Evidence**: `dig` output showing blocked response; Pi-hole Query Log screenshot.

---

### Test 4: Modified Monitored File (FIM)

**Objective**: Verify Wazuh File Integrity Monitoring detects unauthorized file changes.

```bash
# On the Docker host (Wazuh agent monitors key paths):
sudo touch /etc/critical-file-test
echo "test modification" | sudo tee /etc/critical-file-test
sudo chmod 777 /etc/critical-file-test

# Or modify a file in a monitored container:
docker exec shog-pihole touch /etc/pihole/test-file
```

**Expected Results**:
- [ ] Wazuh FIM alert appears in Dashboard within 60 seconds
- [ ] Alert shows: file path, hash change, permission change, user, process
- [ ] Alert severity appropriate to file location

**Evidence**: Wazuh FIM alert screenshot showing file modification details.

**Cleanup**: Remove test files.

---

### Test 5: Blocked VLAN-to-VLAN Connection

**Objective**: Verify VLAN isolation prevents unauthorized cross-network access.

```bash
# From a client on Users VLAN (192.168.20.x):
ping 192.168.10.1        # Management gateway — should FAIL
curl -k https://192.168.40.10:9443  # Portainer — should FAIL
curl http://192.168.40.10:5601      # Wazuh — should FAIL
ssh admin@192.168.40.10             # SSH — should FAIL

# From Management VLAN (should SUCCEED):
ping 192.168.40.10
curl -k https://192.168.40.10:9443  # Should work from mgmt only
```

**Expected Results**:
- [ ] Pings from Users/IoT to Management show 100% packet loss
- [ ] TCP connection attempts timeout or receive RST
- [ ] pfSense filterlog shows blocked entries with source VLAN and destination
- [ ] Wazuh ingests firewall logs and can query blocked attempts

**Evidence**: `ping` output showing failure; pfSense filterlog entry; Wazuh query result.

---

### Test 6: pfSense Firewall Rule Event

**Objective**: Verify firewall rule changes and system events are logged and visible.

```bash
# On pfSense:
# 1. Create a temporary firewall rule via WebGUI
# 2. Delete the temporary rule
# 3. Check system logs for config change events

# Or via CLI (if SSH enabled):
pfSsh.php playback pfconfig
# Then review: Status > System Logs > Firewall
```

**Expected Results**:
- [ ] pfSense system log records rule addition and deletion
- [ ] Syslog forwarded to rsyslog on Docker host
- [ ] Filebeat ships log to Wazuh Indexer
- [ ] Wazuh Dashboard can search/filter firewall rule changes
- [ ] Alert correlation possible (rule change + subsequent traffic pattern change)

**Evidence**: Wazuh Dashboard showing pfSense log entry with rule change details.

---

## 3. Performance Metrics

### 3.1 Alert Latency

| Alert Type | Source | Max Acceptable | Measurement |
|------------|--------|----------------|-------------|
| Suricata IDS alert | Suricata -> rsyslog -> Filebeat -> Wazuh | 60 seconds | `logger` + stopwatch |
| Firewall block log | pfSense -> rsyslog -> Filebeat -> Wazuh | 60 seconds | Generate traffic + query |
| CrowdSec decision | CrowdSec API | 5 minutes | `cscli metrics` |
| Wazuh FIM alert | Wazuh agent -> Manager -> Indexer | 60 seconds | Modify file + check |
| Pi-hole block | Pi-hole direct | 1 second (query time) | `dig` response time |
| DNS propagation | Pi-hole -> Unbound | 5 seconds | First vs cached query |

### 3.2 Attack Detection Rate

Controlled test methodology:

| Attack Type | Attempts | Expected Detections | Detection Rate Target |
|-------------|----------|---------------------|----------------------|
| Port scan (nmap) | 10 | 10 | 100% |
| SSH brute force | 5 sessions | 5 | 100% |
| Malicious DNS | 20 domains | 18+ | >= 90% |
| File modification | 10 files | 10 | 100% |
| VLAN bypass | 5 attempts | 5 (logged, not alerted) | 100% logged |
| Firewall rule change | 3 changes | 3 | 100% |

**Overall detection rate target**: >= 95%

### 3.3 Service Availability (Uptime Kuma)

| Service | Check Method | Target Uptime |
|---------|-------------|---------------|
| Pi-hole DNS | UDP port 53 query | 99.9% |
| Unbound | TCP port 5335 query | 99.9% |
| Wazuh Dashboard | HTTPS health endpoint | 99.5% |
| Portainer | HTTPS API status | 99.5% |
| CrowdSec | `cscli metrics` | 99.5% |
| rsyslog | TCP port 514 accept | 99.9% |
| Uptime Kuma itself | Self-check | N/A |

### 3.4 Resource Utilization

| Metric | Measurement | Target |
|--------|-------------|--------|
| Container startup time | `docker compose up -d` duration | < 5 min |
| Wazuh indexer memory | `docker stats` after 24h | < 2 GB |
| Pi-hole query throughput | `dig` in loop, 1000 queries | < 10 ms avg |
| Disk growth rate | `du -sh` daily over 7 days | < 2 GB/week |
| Log ingestion rate | Wazuh indexer documents/second | > 100 doc/s |
| Dashboard response | Browser devtools, search query | < 3 seconds |

---

## 4. Administrator Usability

### 4.1 System Usability Scale (SUS) Questionnaire

Rate each statement 1 (Strongly Disagree) to 5 (Strongly Agree):

| # | Statement | Score |
|---|-----------|-------|
| 1 | I think that I would like to use SHOG frequently. | _/5 |
| 2 | I found SHOG unnecessarily complex. (R) | _/5 |
| 3 | I thought SHOG was easy to use. | _/5 |
| 4 | I think that I would need the support of a technical person to be able to use SHOG. (R) | _/5 |
| 5 | I found the various functions in SHOG were well integrated. | _/5 |
| 6 | I thought there was too much inconsistency in SHOG. (R) | _/5 |
| 7 | I would imagine that most people would learn to use SHOG very quickly. | _/5 |
| 8 | I found SHOG very cumbersome to use. (R) | _/5 |
| 9 | I felt very confident using SHOG. | _/5 |
| 10 | I needed to learn a lot of things before I could get going with SHOG. (R) | _/5 |

**Scoring**: For odd items: score - 1. For even (R) items: 5 - score. Sum all x 2.5 = SUS score.

| SUS Score | Interpretation |
|-----------|----------------|
| 0-25 | Worst imaginable |
| 25-50 | Poor |
| 50-70 | OK |
| 70-85 | Good |
| 85-100 | Excellent |

**Target SUS score**: >= 70 ("Good")

### 4.2 Task-Based Evaluation

| Task | Time Limit | Success Criteria |
|------|------------|------------------|
| Install SHOG from scratch | 30 minutes | All containers healthy |
| View a security alert | 2 minutes | Navigate to Wazuh, find alert, understand it |
| Add a DNS blocklist | 5 minutes | Pi-hole admin, add URL, verify blocking |
| Check service status | 1 minute | Use health-check.sh or Portainer |
| Restore from backup | 20 minutes | Follow restore.md, all data recovered |
| Add a new VLAN | 15 minutes | pfSense config, test isolation |

### 4.3 Documentation Completeness

| Document | Required Sections | Review Criteria |
|----------|-------------------|-----------------|
| README.md | Quick start, architecture, services | Novice can install without help |
| architecture.md | Diagrams, data flow, ports | Admin understands network layout |
| pfsense-setup.md | Step-by-step, screenshots described | Admin can configure pfSense |
| threat-model.md | Assets, actors, paths, controls | Risk understood, gaps identified |
| troubleshooting.md | Common issues, fixes | Self-service problem resolution |
| restore.md | Full restore procedure | Recovery possible without external help |

---

## 5. Audit Completeness

| Audit Question | Evidence Source | Completeness Target |
|----------------|-----------------|---------------------|
| Who accessed the network? | pfSense DHCP logs + VPN logs | 100% of connections logged |
| What DNS queries were made? | Pi-hole query log | All queries logged |
| What traffic was blocked? | pfSense filterlog + Suricata | 100% of blocks logged |
| Were any files modified? | Wazuh FIM alerts | Monitored paths 100% |
| Were there login attempts? | Host auth.log + Wazuh | All attempts logged |
| Were containers restarted? | Docker events + Portainer logs | All events logged |
| Were threats detected? | CrowdSec decisions + Wazuh alerts | All decisions logged |
| Was configuration changed? | pfSense config history + .env | Changes tracked |

---

## 6. Service Recovery

| Scenario | Recovery Method | Target RTO |
|----------|----------------|------------|
| Single container crash | Docker auto-restart | < 60 seconds |
| Docker host reboot | `docker compose up -d` | < 5 minutes |
| Complete data loss | Restore from backup | < 30 minutes |
| pfSense failure | Restore config.xml | < 15 minutes |
| Corrupt Wazuh index | Reindex from snapshots | < 60 minutes |

**RTO** = Recovery Time Objective

---

## 7. Resource Sizing Table

| Profile | CPU | RAM | Disk | Network | Use Case |
|---------|-----|-----|------|---------|----------|
| **Minimum** | 2 cores | 4 GB | 50 GB SSD | 1 Gbps | Solo developer, basic DNS + monitoring |
| **Recommended** | 4 cores | 8 GB | 100 GB SSD | 1 Gbps | Small team, full SIEM, no OpenCTI |
| **Advanced** | 6+ cores | 16 GB | 200 GB NVMe | 1 Gbps | Full stack + OpenCTI, long retention |
| **Advanced+** | 8+ cores | 32 GB | 500 GB NVMe | 10 Gbps | Multiple VLANs, high throughput, Cluster |

*Minimum profile excludes Wazuh (uses lightweight alternatives) or runs with reduced heap sizes.*

---

## 8. Evaluation Timeline

| Day | Activity | Deliverable |
|-----|----------|-------------|
| 1 | Environment prep, pfSense install | Working pfSense gateway |
| 2 | SHOG deployment (`./install.sh`) | All services healthy |
| 3 | pfSense configuration | VLANs, DNS, Suricata, VPN |
| 4 | Baseline + monitoring setup | Uptime Kuma configured |
| 5 | Benign attack simulations | Detection evidence collected |
| 6 | Performance measurement | Latency + throughput data |
| 7 | Usability evaluation | SUS questionnaire + task times |
| 8 | Documentation review | Completeness checklist |
| 9 | Backup/restore test | Recovery time measured |
| 10 | Analysis + reporting | Evaluation report |
