# SHOG Threat Model

## 1. Asset Inventory

| ID | Asset | Location | Sensitivity | Owner |
|----|-------|----------|-------------|-------|
| A1 | Docker host (Ubuntu) | VLAN 40 | Critical | Admin |
| A2 | Container orchestration data | Docker volumes | Critical | Admin |
| A3 | Wazuh SIEM database | wazuh-indexer-data | Critical | Admin |
| A4 | DNS query logs | Pi-hole SQLite | High | Admin |
| A5 | pfSense firewall config | pfSense flash/VM disk | Critical | Admin |
| A6 | VPN private keys | pfSense + client devices | Critical | Admin |
| A7 | User workstations | VLAN 20 | High | Users |
| A8 | IoT devices | VLAN 30 | Medium | Mixed |
| A9 | Admin credentials | .env, Wazuh, pfSense | Critical | Admin |
| A10 | Network traffic metadata | Suricata EVE JSON | High | Admin |
| A11 | TLS certificates | Wazuh, services | High | System |
| A12 | Threat intelligence feeds | CrowdSec, OpenCTI | Medium | Services |

## 2. Threat Actors

| ID | Actor | Motivation | Capability | Likelihood |
|----|-------|------------|------------|------------|
| T1 | Script kiddie / automated scanner | Opportunistic compromise | Low (tools) | High |
| T2 | Malware / botnet | Propagation, DDoS recruitment | Low-Medium | High |
| T3 | Phishing attacker | Credential theft, lateral movement | Medium | Medium |
| T4 | Insider (curious user) | Access unauthorized resources | Low-Medium | Low |
| T5 | Insider (malicious) | Data theft, service disruption | Medium | Low |
| T6 | APT / targeted attacker | Espionage, persistent access | High | Very Low |
| T7 | Supply chain (compromised image) | Backdoor deployment | Medium | Low |

## 3. Attack Paths

### Path 1: External Network Compromise
```
Internet --> [pfSense WAN] --> ?
```
- Port scan against WAN
- Exploit pfSense vulnerability
- VPN credential brute force
- **Controls**: pfSense firewall (block all inbound), Suricata (detect scan patterns), WireGuard strong keys, auto-update pfSense

### Path 2: DNS-based Attack
```
LAN Client --> [DNS request] --> Bypass Pi-hole --> Malicious domain
```
- Direct DNS to 8.8.8.8 bypassing Pi-hole
- DNS over HTTPS (DoH) bypass
- DNS cache poisoning
- **Controls**: Firewall blocks outbound UDP 53 except from Pi-hole, DoH/DoT port blocking, Pi-hole blocklists, Unbound DNSSEC validation

### Path 3: Lateral Movement from IoT
```
IoT Device (compromised) --> [VLAN 30] --> Scan other VLANs --> Lateral movement
```
- Compromised IoT device scans internal network
- Exploit known IoT vulnerability
- Weak/default IoT credentials
- **Controls**: VLAN isolation (IoT cannot reach Users/Servers/Management), firewall rules deny inter-VLAN, CrowdSec detects scan behaviour, Wazuh logs firewall denies

### Path 4: Container Escape
```
Exploit vulnerable container --> Docker host access --> Container data theft
```
- Exploit service vulnerability (web RCE)
- Container misconfiguration (privileged, socket mount)
- Kernel vulnerability via container
- **Controls**: No-new-privileges, dropped capabilities, read-only rootfs where possible, restricted Docker socket access (Portainer only), AppArmor/SELinux, Wazuh agent monitors host, regular image updates

### Path 5: Credential Compromise
```
Phish admin --> Steal .env or login --> Full stack control
```
- Spear phishing for admin credentials
- Brute force admin web UIs
- Credential stuffing
- **Controls**: Admin UIs on Management VLAN only, VPN required for remote access, strong auto-generated passwords, Wazuh brute-force detection, fail2ban on host, MFA where supported

### Path 6: Supply Chain / Image Compromise
```
Compromised base image --> Deploy backdoored container --> Persist access
```
- Malicious image on Docker Hub
- Compromised build pipeline
- **Controls**: Pinned image versions (not :latest), image hash verification, private registry option documented, minimal base images (Alpine), regular security scans (Trivy recommended)

### Path 7: Data Exfiltration via DNS Tunneling
```
Malware on client --> DNS queries to attacker domain --> Exfil data
```
- DNS tunneling (iodine, dnscat2)
- Slow data exfil via DNS queries
- **Controls**: Pi-hole blocks known DNS tunneling domains, Unbound query logging, Wazuh detects anomalous query patterns, Suricata DNS anomaly detection

### Path 8: Physical/Docker Host Compromise
```
Physical access --> Ubuntu host --> All container data exposed
```
- Boot from USB to bypass OS
- Direct console access
- **Controls**: Full-disk encryption (LUKS), BIOS/UEFI password, secure boot, GRUB password, physical access controls, automatic screen lock

## 4. Security Controls Matrix

| Control | Type | Targets | Effectiveness | Automated? |
|---------|------|---------|---------------|------------|
| pfSense edge firewall | Prevent | Paths 1, 2 | High | Yes (pfSense) |
| VLAN segmentation | Prevent | Path 3 | High | Yes (pfSense) |
| Pi-hole DNS filtering | Prevent | Paths 2, 7 | Medium-High | Yes (Docker) |
| Unbound + DNSSEC | Prevent | Path 2 | Medium | Yes (Docker) |
| Suricata IDS | Detect | Path 1, 2, 7 | High | Yes (pfSense) |
| CrowdSec | Detect/Prevent | Paths 1, 3, 4 | Medium-High | Yes (Docker) |
| Wazuh SIEM | Detect | All paths | High | Yes (Docker) |
| Wazuh FIM | Detect | Path 4, 5, 8 | Medium-High | Yes (Docker) |
| Docker security options | Prevent | Path 4 | Medium | Yes (compose) |
| Least privilege (capabilities) | Prevent | Path 4 | Medium | Yes (compose) |
| Auto secret generation | Prevent | Path 5 | High | Yes (install.sh) |
| Admin UI network binding | Prevent | Path 5 | High | Yes (compose) |
| Management VLAN restriction | Prevent | Path 5 | High | Yes (pfSense) |
| WireGuard VPN | Prevent | Path 1, 5 | High | Yes (pfSense) |
| Image version pinning | Prevent | Path 6 | Medium | Yes (compose) |
| Health checks + auto-restart | Resilience | All paths | Medium | Yes (compose) |
| Backup + restore | Resilience | All paths | High | Yes (backup.sh) |
| Log rotation | Resilience | Disk exhaustion | Medium | Yes (compose + host) |
| Full-disk encryption | Prevent | Path 8 | High | Manual |

## 5. Residual Risk Assessment

| Risk | Severity (1-5) | Likelihood (1-5) | Risk Score | Residual After Controls |
|------|---------------|-------------------|------------|------------------------|
| External network breach | 5 | 2 | 10 | Low (Suricata + CrowdSec + pfSense) |
| DNS bypass for malware C2 | 4 | 3 | 12 | Low-Medium (Pi-hole + DoH block) |
| IoT lateral movement | 4 | 3 | 12 | Low (VLAN isolation) |
| Container escape to host | 5 | 2 | 10 | Low (Docker hardening + Wazuh FIM) |
| Admin credential theft | 5 | 2 | 10 | Low (network isolation + strong passwords) |
| Supply chain compromise | 4 | 1 | 4 | Low (pinned versions) |
| DNS tunneling exfiltration | 4 | 2 | 8 | Low-Medium (Pi-hole + Wazuh) |
| Physical host compromise | 5 | 1 | 5 | Medium (requires FDE - manual) |
| Zero-day in pfSense | 5 | 1 | 5 | Medium (auto-updates mitigate) |
| DoS against Docker host | 3 | 3 | 9 | Low-Medium (resource limits + CrowdSec) |

**Risk Score = Severity x Likelihood**
- 1-4: Low (acceptable)
- 5-9: Medium (monitor, review periodically)
- 10-16: High (active mitigation required)
- 17-25: Critical (immediate action required)

## 6. Security Monitoring Coverage

| Data Source | What It Proves | Gaps/Limitations |
|-------------|----------------|------------------|
| pfSense firewall logs | All allowed/blocked connections; proves network policy enforcement | Encrypted traffic content not visible; logging volume can be high |
| Suricata EVE JSON | IDS alerts, protocol anomalies, malware indicators | Encrypted traffic (TLS 1.3) limits inspection; false positives possible |
| Pi-hole query logs | DNS request provenance; blocked domain attempts | Encrypted DNS (DoH) bypasses; cached queries may not log |
| Wazuh agent telemetry | Host integrity, file changes, process execution, logins | Requires agent on monitored host; kernel-level rootkits may evade |
| CrowdSec decisions | Automated threat response; blocked IPs | IP-based only; behind CGNAT shared IPs may cause over-blocking |
| Docker container logs | Application errors, access patterns | Dependent on application logging quality; rotation may lose data |
| Uptime Kuma | Service availability proof | Only synthetic checks; real user issues may differ |

## 7. Attack-Detection Mapping

| Attack Technique | Detection Source | Detection Tool | Expected Evidence |
|-----------------|------------------|----------------|-------------------|
| Port scan (WAN) | Suricata | Wazuh Dashboard | ET SCAN alert in Suricata EVE |
| Port scan (LAN) | pfSense logs | Wazuh Dashboard | "filterlog: block" with multiple destination ports |
| Brute force SSH | Host auth.log | CrowdSec + Wazuh | CrowdSec decision; Wazuh rule 5712 (SSHD brute force) |
| Malware DNS query | Pi-hole query log | Pi-hole + Wazuh | Blocked domain in Pi-hole query log; Wazuh CDB lookup |
| File modification | Wazuh FIM | Wazuh Dashboard | FIM alert with hash change, user, process |
| VLAN bypass attempt | pfSense logs | Wazuh Dashboard | Blocked traffic between VLANs in filterlog |
| Firewall rule change | pfSense system log | Wazuh Dashboard | Config event: "There were error(s) loading the rules" or success |
| Container anomaly | Docker events | Wazuh + CrowdSec | Privileged container start, unexpected image |
| Suspicious process | Host /proc | Wazuh | Syscheck process monitoring alert |
| DoH/DoT bypass attempt | Firewall logs | Wazuh Dashboard | Blocked TCP 443 to known DoH IP; repeated blocked connections |
