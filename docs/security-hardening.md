# SHOG Security Hardening Guide

This document describes additional hardening measures beyond the SHOG defaults. Implement these based on your threat model and risk tolerance.

---

## 1. Host-Level Hardening (Ubuntu Docker Host)

### 1.1 Automatic Security Updates

```bash
sudo apt install unattended-upgrades
sudo dpkg-reconfigure unattended-upgrades
# Select "Yes"

# Configure:
sudo tee /etc/apt/apt.conf.d/50unattended-upgrades > /dev/null <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::InstallOnShutdown "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
```

### 1.2 fail2ban

```bash
sudo apt install fail2ban
sudo tee /etc/fail2ban/jail.local > /dev/null <<'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
banaction = ufw
backend = systemd

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 7200

[docker]
enabled = true
port = 9443,5601,3001,8080
filter = docker
logpath = /var/log/auth.log
maxretry = 5
EOF

sudo systemctl enable --now fail2ban
```

### 1.3 UFW (Uncomplicated Firewall)

```bash
# Default deny
sudo ufw default deny incoming
sudo ufw default allow outgoing

# Allow SSH from management VLAN only
sudo ufw allow from 192.168.10.0/24 to any port 22 proto tcp

# Allow Docker management UIs from management VLAN
sudo ufw allow from 192.168.10.0/24 to any port 9443 proto tcp
sudo ufw allow from 192.168.10.0/24 to any port 5601 proto tcp
sudo ufw allow from 192.168.10.0/24 to any port 3001 proto tcp
sudo ufw allow from 192.168.10.0/24 to any port 8080 proto tcp

# Allow DNS from all internal VLANs
sudo ufw allow from 192.168.20.0/24 to any port 53 proto udp
sudo ufw allow from 192.168.30.0/24 to any port 53 proto udp
sudo ufw allow from 192.168.40.0/24 to any port 53 proto udp

# Allow syslog from pfSense
sudo ufw allow from 192.168.40.1 to any port 514 proto udp

# Enable (CAUTION: ensure you have alternative access)
sudo ufw enable
```

**Important**: Docker bypasses UFW by default. Add to `/etc/ufw/after.rules`:
```
*filter
:DOCKER-USER - [0:0]
-A DOCKER-USER -i eth0 -j RETURN
COMMIT
```

Better: use `iptables` rules or the CrowdSec bouncer profile.

### 1.4 SSH Hardening

```bash
sudo tee /etc/ssh/sshd_config.d/shog.conf > /dev/null <<'EOF'
# Disable root login
PermitRootLogin no

# Key authentication only
PasswordAuthentication no
PubkeyAuthentication yes

# Limit to management subnet
Match Address 192.168.10.0/24,10.200.200.0/24
    PasswordAuthentication no
    PubkeyAuthentication yes
    X11Forwarding no
    AllowTcpForwarding no
    ForceCommand internal-sftp

# Deny all other
Match all
    DenyUsers *
    DenyGroups *
EOF

# Add exception for your admin user:
# sudo tee -a /etc/ssh/sshd_config.d/shog.conf <<EOF
# Match User your-admin Address 192.168.10.0/24,10.200.200.0/24
#     AllowUsers your-admin
#     ForceCommand none
#     AllowTcpForwarding yes
# EOF

sudo systemctl restart sshd
```

### 1.5 Auditd (Linux Audit Framework)

```bash
sudo apt install auditd audispd-plugins

# Monitor critical files
sudo auditctl -w /etc/passwd -p wa -k identity
sudo auditctl -w /etc/group -p wa -k identity
sudo auditctl -w /etc/shadow -p wa -k identity
sudo auditctl -w /etc/ssh/sshd_config -p wa -k sshd_config
sudo auditctl -w /var/run/docker.sock -p wa -k docker_socket
sudo auditctl -w /usr/bin/docker -p x -k docker_binary
sudo auditctl -w /usr/local/bin/docker-compose -p x -k compose_binary
sudo auditctl -w /etc/shog/.env -p wa -k shog_secrets

# Make persistent
echo "-w /etc/shog/.env -p wa -k shog_secrets" | sudo tee -a /etc/audit/rules.d/shog.rules
sudo augenrules --load
```

### 1.6 Kernel Hardening (sysctl)

```bash
sudo tee /etc/sysctl.d/99-security.conf > /dev/null <<'EOF'
# IP Spoofing protection
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Ignore ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Ignore send redirects
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Disable source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0

# Log martian packets
net.ipv4.conf.all.log_martians = 1

# SYN flood protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 5

# Disable IPv6 if not used
# net.ipv6.conf.all.disable_ipv6 = 1
# net.ipv6.conf.default.disable_ipv6 = 1
EOF

sudo sysctl --system
```

---

## 2. Docker-Level Hardening

### 2.1 Docker Daemon Configuration

```bash
sudo tee /etc/docker/daemon.json > /dev/null <<'EOF'
{
  "userns-remap": "default",
  "live-restore": true,
  "no-new-privileges": true,
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3",
    "labels": "shog.service",
    "env": "OS_VERSION"
  },
  "selinux-enabled": false,
  "apparmor-default": "docker-default",
  "seccomp-profile": "/etc/docker/seccomp-default.json",
  "storage-driver": "overlay2",
  "storage-opts": [
    "overlay2.override_kernel_check=true"
  ]
}
EOF

sudo systemctl restart docker
```

**Note**: `userns-remap` may cause permission issues with volume mounts. Test thoroughly before enabling in production.

### 2.2 Docker Socket Protection

The Docker socket (`/var/run/docker.sock`) is mounted read-only into Portainer and Uptime Kuma. For additional protection:

```bash
# Option A: Docker socket proxy (recommended)
# Add to compose.override.yml:
#   socket-proxy:
#     image: tecnativa/docker-socket-proxy:0.1.1
#     environment:
#       CONTAINERS: 1
#       SERVICES: 1
#       TASKS: 1
#       NODES: 0
#       NETWORKS: 0
#       IMAGES: 0
#       INFO: 1
#     volumes:
#       - /var/run/docker.sock:/var/run/docker.sock:ro
#     networks:
#       - management
#
# Then mount the proxy socket into Portainer:
#   portainer:
#     volumes:
#       - socket-proxy:/var/run/docker.sock:ro
```

### 2.3 Container Image Scanning

```bash
# Install Trivy
wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key | sudo apt-key add -
echo "deb https://aquasecurity.github.io/trivy-repo/deb $(lsb_release -sc) main" | sudo tee /etc/apt/sources.list.d/trivy.list
sudo apt update && sudo apt install trivy

# Scan all SHOG images
trivy image mvance/unbound:1.19.0
trivy image pihole/pihole:2024.02.2
trivy image wazuh/wazuh-manager:4.7.2
trivy image crowdsecurity/crowdsec:v1.6.0
trivy image portainer/portainer-ce:2.19.4
trivy image louislam/uptime-kuma:1.23.11
```

Schedule weekly scans:
```bash
# Add to crontab:
# 0 3 * * 1 /usr/local/bin/trivy image --exit-code 0 --severity HIGH,CRITICAL mvance/unbound:1.19.0 >> /var/log/trivy-scan.log 2>&1
```

### 2.4 Rootless Docker (Advanced)

Consider rootless Docker mode for additional isolation:

```bash
dockerd-rootless-setuptool.sh install
export DOCKER_HOST=unix://$XDG_RUNTIME_DIR/docker.sock
```

This runs Docker daemon as unprivileged user. Note: Some features (privileged containers, certain network modes) are not available.

---

## 3. Application-Level Hardening

### 3.1 Wazuh — Custom Rules

Add custom detection rules to `configs/wazuh/local_rules.xml`:

```xml
<group name="shog_custom">
  <!-- Detect Docker socket access from unexpected containers -->
  <rule id="100001" level="10">
    <decoded_as>json</decoded_as>
    <field name="container.name">^shog-</field>
    <field name="audit.type">CONNECT</field>
    <match>/var/run/docker.sock</match>
    <description>Docker socket access detected from $(container.name)</description>
  </rule>

  <!-- Detect unusual DNS query volume (possible tunneling) -->
  <rule id="100002" level="8" frequency="100" timeframe="60">
    <if_matched_sid>100003</if_matched_sid>
    <description>High volume of DNS queries from $(srcip) — possible DNS tunneling</description>
  </rule>
</group>
```

### 3.2 CrowdSec — Custom Scenarios

Create custom detection scenarios in `configs/crowdsec/scenarios/shog-custom.yaml`:

```yaml
type: leaky
name: shog/shog-admin-bruteforce
description: "Detect brute force against SHOG admin interfaces"
filter: "evt.Meta.service == 'http' && evt.Parsed.request contains '/admin'"
groupby: evt.Meta.source_ip
capacity: 5
leakspeed: 60s
blackhole: 5m
labels:
  type: bruteforce
  remediation: true
```

### 3.3 Pi-hole — Enhanced Blocklists

Recommended blocklists for security:

```
# Firebog's curated lists — add in Pi-hole admin:
https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts
https://mirror1.malwaredomains.com/files/justdomains
https://sysctl.org/cameleon/hosts
https://s3.amazonaws.com/lists.disconnect.me/simple_tracking.txt
https://s3.amazonaws.com/lists.disconnect.me/simple_ad.txt
https://gitlab.com/quidsup/notrack-blocklists/raw/master/notrack-blocklist.txt

# DNS over HTTPS domains (block bypass attempts):
https://raw.githubusercontent.com/hagezi/dns-blocklists/main/doh/doh.txt
```

### 3.4 Portainer — Authentication

1. First visit: Create strong admin password immediately
2. Enable LDAP or OAuth if available (Settings > Authentication)
3. Set session timeout: Settings > Security > Session lifetime: 8 hours
4. Enable activity logging: Settings > Activity logs
5. Create non-admin users for read-only access if needed

### 3.5 Uptime Kuma — Security

1. First visit: Create strong admin password
2. Enable 2FA in Settings if available
3. Disable public status page unless needed
4. Set notification for all monitors

---

## 4. Network-Level Hardening

### 4.1 Disable Unused Services on Docker Host

```bash
sudo systemctl disable --now cups
sudo systemctl disable --now avahi-daemon
sudo systemctl disable --now bluetooth
sudo systemctl disable --now ModemManager
```

### 4.2 Network Segmentation Verification

Regularly verify VLAN isolation:

```bash
# From Docker host, verify cross-VLAN blocking
nc -zv -w 2 192.168.20.1 80    # Should fail (Users VLAN)
nc -zv -w 2 192.168.30.1 80    # Should fail (IoT VLAN)
nc -zv -w 2 192.168.10.1 80    # Should succeed (Management VLAN)
```

### 4.3 Certificate Management

For production, replace Wazuh demo certificates:

```bash
# Generate proper CA and certs
cd /opt/shog/configs/wazuh
mkdir -p certs && cd certs

# Generate CA
openssl genrsa -out root-ca-key.pem 2048
openssl req -new -x509 -sha256 -key root-ca-key.pem -out root-ca.pem -days 3650 \
  -subj "/C=US/ST=State/L=City/O=HomeLab/CN=SHOG Root CA"

# Generate node cert
openssl genrsa -out node-key.pem 2048
openssl req -new -key node-key.pem -out node.csr \
  -subj "/C=US/ST=State/L=City/O=HomeLab/CN=shog-wazuh-indexer"
openssl x509 -req -in node.csr -CA root-ca.pem -CAkey root-ca-key.pem \
  -CAcreateserial -sha256 -out node.pem -days 365
```

Then update `wazuh_indexer.yml` with proper certificate paths.

---

## 5. Monitoring and Alerting

### 5.1 Host Intrusion Detection

Consider adding OSSEC HIDS or AIDE for additional host-level detection:

```bash
sudo apt install aide
sudo aideinit
# Review /var/lib/aide/aide.db.new
cp /var/lib/aide/aide.db.new /var/lib/aide/aide.db

# Daily check via cron:
# 0 4 * * * /usr/bin/aide --check | mail -s "AIDE Check $(hostname)" admin@example.com
```

### 5.2 Security Metrics Dashboard

Create a Wazuh custom dashboard for:
- Top 10 blocked IPs (CrowdSec)
- DNS query volume over time (Pi-hole via custom script)
- Failed login attempts (Wazuh auth.log analysis)
- Suricata alert severity distribution
- Container restart count (Docker events)

### 5.3 Alert Escalation

Configure alert profiles:

| Severity | Delivery | Response Time |
|----------|----------|---------------|
| Critical | Immediate webhook + email | 15 minutes |
| High | Webhook within 5 min | 1 hour |
| Medium | Daily digest | 24 hours |
| Low | Weekly summary | 7 days |

---

## 6. Compliance Notes

This hardening guide addresses controls from common frameworks:

| Framework | Control Area | SHOG Implementation |
|-----------|-------------|---------------------|
| NIST CSF | Protect (PR.AC, PR.PT) | VLANs, least privilege, VPN |
| NIST CSF | Detect (DE.AE, DE.CM) | Wazuh, Suricata, CrowdSec |
| NIST CSF | Respond (RS.AN, RS.MI) | Automated blocking, alerting |
| ISO 27001 | A.13.1 (Network security) | pfSense, segmentation |
| ISO 27001 | A.12.4 (Logging) | Centralised syslog, SIEM |
| CIS Controls | CIS 4 (Controlled admin) | Management VLAN, VPN |
| CIS Controls | CIS 6 (Audit logs) | Wazuh, rsyslog, retention |
| CIS Controls | CIS 8 (Malware defences) | Pi-hole, CrowdSec, Suricata |
| CIS Controls | CIS 12 (Network monitoring) | Suricata, IDS/IPS |
| CIS Controls | CIS 13 (Network architecture) | VLANs, firewall rules |
