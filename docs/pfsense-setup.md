# pfSense Setup Guide

> **IMPORTANT**: pfSense CE is deployed **outside Docker** as a dedicated firewall appliance (bare metal or VM). This document covers all manual pfSense configuration required for SHOG.

---

## Table of Contents

1. [Hardware/VM Requirements](#hardware-requirements)
2. [Initial Installation](#initial-installation)
3. [WAN Configuration](#wan-configuration)
4. [LAN Configuration](#lan-configuration)
5. [VLAN Setup](#vlan-setup)
6. [Firewall Rules](#firewall-rules)
7. [DNS Configuration](#dns-configuration)
8. [Suricata IDS](#suricata-ids)
9. [Syslog Forwarding](#syslog-forwarding)
10. [WireGuard VPN](#wireguard-vpn)
11. [Admin Access Restriction](#admin-access-restriction)

---

## Hardware Requirements

| Spec | Minimum | Recommended |
|------|---------|-------------|
| CPU | 2 cores @ 1.8 GHz | 4 cores @ 2.0+ GHz |
| RAM | 4 GB | 8 GB (for Suricata) |
| Storage | 32 GB SSD | 60 GB SSD |
| NICs | 2 | 3+ (for VLANs) |

## Initial Installation

1. Download pfSense CE ISO from https://www.pfsense.org/download/
2. Install on bare metal or VM (Proxmox, ESXi, etc.)
3. During setup:
   - Assign WAN to the NIC connected to your ISP
   - Assign LAN to the NIC connected to your internal network
   - Do NOT assign the LAN IP as your Docker host IP

---

## WAN Configuration

```
Interfaces > WAN
```

| Setting | Value | Notes |
|---------|-------|-------|
| IPv4 Configuration | DHCP or PPPoE | As required by ISP |
| IPv6 Configuration | None or DHCP6 | Disable if not needed |
| Block RFC1918 | Checked | Prevent spoofing |
| Block bogon networks | Checked | |
| MTU | 1500 (or 1492 for PPPoE) | |

**If behind an existing ISP router** (double-NAT scenario):
1. Put ISP router in bridge/pass-through mode (preferred), OR
2. Add DMZ on ISP router pointing to pfSense WAN IP, OR
3. Port-forward required ports to pfSense WAN IP

---

## LAN Configuration

```
Interfaces > LAN
```

| Setting | Value |
|---------|-------|
| Enable | Checked |
| IPv4 Configuration | Static IPv4 |
| IPv4 Address | 192.168.40.1/24 |
| IPv6 Configuration | None (or as needed) |

### DHCP Server (Services > DHCP Server > LAN)

| Setting | Value |
|---------|-------|
| Enable | Checked |
| Range | 192.168.40.100 to 192.168.40.200 |
| DNS Server | 192.168.40.10 (Pi-hole/Docker host) |
| Gateway | 192.168.40.1 |
| Domain | home.lan |
| Lease time | 7200 seconds |

**Static mappings** (add your Docker host):

| MAC Address | IP Address | Hostname | Description |
|-------------|------------|----------|-------------|
| aa:bb:cc:dd:ee:ff | 192.168.40.10 | shog-docker | Docker host |

---

## VLAN Setup

Navigate to `Interfaces > Assignments > VLANs` and create:

### VLAN 10 — Management

| Setting | Value |
|---------|-------|
| Parent Interface | LAN (igb1/vmx1) |
| VLAN Tag | 10 |
| Description | Management |

Then assign: `Interfaces > Assignments` → Add `VLAN 10 on LAN` as OPT1

**Interface Configuration (OPT1 / Management):**

| Setting | Value |
|---------|-------|
| Enable | Checked |
| IPv4 Address | 192.168.10.1/24 |

**DHCP (Management VLAN):**

| Setting | Value |
|---------|-------|
| Range | 192.168.10.10 to 192.168.10.50 |
| DNS Server | 192.168.40.10 (Pi-hole) |

### VLAN 20 — Users

| Setting | Value |
|---------|-------|
| VLAN Tag | 20 |
| Description | Users |
| IPv4 Address | 192.168.20.1/24 |
| DHCP Range | 192.168.20.100 - 192.168.20.200 |
| DNS Server | 192.168.40.10 |

### VLAN 30 — IoT / Guest

| Setting | Value |
|---------|-------|
| VLAN Tag | 30 |
| Description | IoT_Guest |
| IPv4 Address | 192.168.30.1/24 |
| DHCP Range | 192.168.30.100 - 192.168.30.200 |
| DNS Server | 192.168.40.10 |

### Switch Configuration

If using a managed switch, configure trunk port to pfSense:

| Switch Port | Mode | VLANs |
|-------------|------|-------|
| Port to pfSense | Trunk | 10, 20, 30, 40 (tagged) |
| Port to Docker host | Access | 40 (untagged) |
| Admin workstation | Access | 10 (untagged) |
| User ports | Access | 20 (untagged) |
| IoT/Guest ports | Access | 30 (untagged) |

---

## Firewall Rules

### WAN Rules (Firewall > Rules > WAN)

| Action | Protocol | Source | Port | Destination | Description |
|--------|----------|--------|------|-------------|-------------|
| Block | IPv4* | * | * | * | Default deny all (already present) |

No inbound access from WAN (VPN is used for remote access).

### LAN Rules (Firewall > Rules > LAN)

Allow basic services, DNS redirected to Pi-hole:

| Action | Protocol | Source | Port | Destination | Description |
|--------|----------|--------|------|-------------|-------------|
| Pass | TCP/UDP | LAN net | 53 | 192.168.40.10 | DNS to Pi-hole |
| Block | TCP/UDP | LAN net | 53 | !192.168.40.10 | Block external DNS |
| Pass | TCP | LAN net | 80,443 | Any | Web browsing |
| Pass | TCP/UDP | LAN net | 443 | Any | HTTPS (required for DoH) |
| Pass | TCP | LAN net | 22 | Management net | SSH to management |
| Pass | ICMP | LAN net | * | Any | Ping (limit if desired) |
| Block | * | LAN net | * | Management net | Deny to management |
| Pass | * | LAN net | * | !RFC1918 | Internet access |

### Management VLAN Rules (Firewall > Rules > OPT1)

Most restrictive — admin access only:

| Action | Protocol | Source | Port | Destination | Description |
|--------|----------|--------|------|-------------|-------------|
| Pass | TCP | Management net | 9443 | 192.168.40.10 | Portainer |
| Pass | TCP | Management net | 5601 | 192.168.40.10 | Wazuh |
| Pass | TCP | Management net | 3001 | 192.168.40.10 | Uptime Kuma |
| Pass | TCP | Management net | 8080 | 192.168.40.10 | Pi-hole admin |
| Pass | TCP | Management net | 22 | 192.168.40.10 | SSH to Docker host |
| Pass | TCP | Management net | 80,443 | Any | Web for admin |
| Pass | UDP | Management net | 51820 | WAN address | WireGuard inbound |
| Block | * | Any | * | Management net | Deny all others |
| Pass | * | Management net | * | Any | Admin outbound |

### Users VLAN Rules (Firewall > Rules > OPT2)

| Action | Protocol | Source | Port | Destination | Description |
|--------|----------|--------|------|-------------|-------------|
| Pass | TCP/UDP | Users net | 53 | 192.168.40.10 | DNS to Pi-hole |
| Block | TCP/UDP | Users net | 53 | !192.168.40.10 | Block rogue DNS |
| Pass | TCP/UDP | Users net | 80,443 | Any | Web only |
| Block | * | Users net | * | Management net | No admin access |
| Block | * | Users net | * | Servers net | Restrict server access |
| Pass | * | Users net | * | Any | General internet |

### IoT/Guest VLAN Rules (Firewall > Rules > OPT3)

Most locked down:

| Action | Protocol | Source | Port | Destination | Description |
|--------|----------|--------|------|-------------|-------------|
| Pass | TCP/UDP | IoT net | 53 | 192.168.40.10 | DNS to Pi-hole |
| Block | TCP/UDP | IoT net | 53 | !192.168.40.10 | Block external DNS |
| Pass | TCP | IoT net | 80,443 | Any | Web only |
| Block | * | IoT net | * | Management net | |
| Block | * | IoT net | * | Users net | |
| Block | * | IoT net | * | Servers net | |
| Pass | UDP | IoT net | 123 | Any | NTP |
| Block | * | IoT net | * | !IoT net | Deny inter-VLAN |

---

## DNS Configuration

### Point pfSense to Pi-hole

```
System > General Setup > DNS Server Settings
```

| Setting | Value |
|---------|-------|
| DNS Server 1 | 192.168.40.10 |
| DNS Server 2 | None (or backup) |
| DNS Resolution Behavior | Use local DNS, fall back to remote |
| DNS Query Forwarding | Unchecked (let Pi-hole resolve) |

### Configure Pi-hole as DNS for DHCP clients

This is already set in the DHCP server configuration above (DNS Server = 192.168.40.10).

### Prevent DNS Bypass (DNS over HTTPS/TLS blocking)

Services > DNS Resolver > General Settings:
- Enable DNS Resolver: **Unchecked** (Pi-hole handles DNS)

Firewall rules to block common DoH/DoT ports:

| Action | Protocol | Source | Port | Destination | Description |
|--------|----------|--------|------|-------------|-------------|
| Block | TCP | LAN/VLANs | 853 | Any | Block DNS over TLS |
| Block | TCP | LAN/VLANs | 443 | Known DoH IPs | Block DNS over HTTPS |

Known DoH server list (maintain manually or use pfBlockerNG):
- 8.8.8.8, 8.8.4.4 (Google)
- 1.1.1.1, 1.0.0.1 (Cloudflare)
- 9.9.9.9 (Quad9)
- 208.67.222.222 (OpenDNS)

Also add Pi-hole blocklists for DoH domains.

---

## Suricata IDS

### Installation

```
System > Package Manager > Available Packages
```

Install `suricata` package.

### Interface Configuration

```
Services > Suricata > Interfaces > Add
```

| Setting | Value |
|---------|-------|
| Interface | WAN |
| Enable | Checked |
| Block offenders | Unchecked (IDS mode for thesis) or Checked (IPS) |
| Barnyard2 | Unchecked |

### EVE JSON Output (critical for SHOG)

```
Services > Suricata > Interfaces > WAN > EVE Output
```

| Setting | Value |
|---------|-------|
| Enable EVE | Checked |
| EVE Output Type | FILE AND SYSLOG |
| EVE Syslog Output Facility | local1 |
| EVE Syslog Output Priority | notice |
| EVE Logged Info | Alerts, HTTP, DNS, TLS, Files, SSH, SMTP |
| EVE JSON Format | Compact (single line) |

### Rule Configuration

```
Services > Suricata > Global Settings > Rules
```

Enable:
- Emerging Threats Open (free)
- Snort VRT rules (registered user — free)

Update frequency: 12 hours.

### Alert Testing

Run this from a client to generate a Suricata alert:
```bash
# EICAR test (safe anti-malware test file)
curl -s http://eicar.org/download/eicar.com.txt

# Port scan test
nmap -sS -p 1-1000 192.168.40.10
```

---

## Syslog Forwarding

### Forward pfSense Logs to Docker Host

```
Status > System Logs > Settings
```

| Setting | Value |
|---------|-------|
| Enable Remote Logging | Checked |
| Source Address | LAN address (192.168.40.1) |
| IP Protocol | IPv4 |
| Remote log servers | 192.168.40.10:514 (syslog) |
| Remote Syslog Contents | Everything |

### Forward Suricata Logs

```
Services > Suricata > Interfaces > WAN > Edit
```

Ensure EVE syslog output is enabled (see Suricata section above).

Also enable system log forwarding:

```
Services > Suricata > Interfaces > WAN > Log Mgmt
```

Send Suricata logs to system log: **Checked**

---

## WireGuard VPN

### Installation

```
System > Package Manager > Available Packages > wireguard
```

### Tunnel Configuration

```
VPN > WireGuard > Tunnels > Add Tunnel
```

| Setting | Value |
|---------|-------|
| Enable | Checked |
| Description | SHOG Admin Access |
| Interface Keys | Generate new key pair |
| Listen Port | 51820 |
| Interface Address | 10.200.200.1/24 |

### Peer Configuration (Admin Client)

```
VPN > WireGuard > Peers > Add Peer
```

| Setting | Value |
|---------|-------|
| Tunnel | shog-admin-access |
| Description | Admin Laptop |
| Public Key | ( client's public key ) |
| Allowed IPs | 192.168.10.0/24, 192.168.40.0/24 |
| Persistent Keepalive | 25 |

### Assign WireGuard Interface

```
Interfaces > Assignments
```

Add `wg0` as OPT4, enable, set static IPv4: 10.200.200.1/24

### Firewall Rules for WireGuard

```
Firewall > Rules > WireGuard
```

| Action | Protocol | Source | Port | Destination | Description |
|--------|----------|--------|------|-------------|-------------|
| Pass | * | WireGuard net | * | Management net | Admin VPN access |
| Pass | * | WireGuard net | * | Servers net | Access to Docker host |
| Block | * | WireGuard net | * | IoT net | No IoT access from VPN |

### Client Configuration

```ini
[Interface]
PrivateKey = <client private key>
Address = 10.200.200.2/32
DNS = 192.168.40.10

[Peer]
PublicKey = <server public key>
AllowedIPs = 192.168.10.0/24, 192.168.40.0/24
Endpoint = <your-wan-ip-or-hostname>:51820
PersistentKeepalive = 25
```

---

## Admin Access Restriction

### WebGUI Access Control

```
System > Advanced > Admin Access
```

| Setting | Value |
|---------|-------|
| Protocol | HTTPS |
| TCP Port | 4433 (non-standard) |
| WebGUI redirect | Unchecked |
| WebGUI login autocompletion | Unchecked |
| Anti-lockout | Checked (LAN only) |

### Anti-Lockout Rule Adjustment

```
Firewall > Rules > LAN
```

The anti-lockout rule allows access to the web interface from LAN. If using VLANs, ensure management VLAN can reach the web interface:

| Action | Protocol | Source | Port | Destination | Description |
|--------|----------|--------|------|-------------|-------------|
| Pass | TCP | Management net | 4433 | This firewall | WebGUI access |

### SSH Access

```
System > Advanced > Admin Access > SSH
```

| Setting | Value |
|---------|-------|
| SSHd Enable | Checked |
| SSH port | 22 (or non-standard) |
| Login with keys only | Recommended |
| Disable password login | For key-only auth |

Restrict SSH source to management VLAN via firewall rule.

---

## pfBlockerNG (Optional Enhancement)

For GeoIP blocking and additional threat feeds:

```
System > Package Manager > pfBlockerNG
```

Configure IP feeds for GeoIP and known threat lists. This complements Pi-hole (DNS blocking) with IP-level blocking.

---

## Verification Checklist

- [ ] WAN interface has IP from ISP
- [ ] LAN interface static IP set (192.168.40.1/24)
- [ ] DHCP enabled on LAN with DNS = 192.168.40.10
- [ ] VLANs 10, 20, 30 created and interfaces assigned
- [ ] Firewall rules block inter-VLAN traffic as designed
- [ ] Pi-hole responds to DNS queries from LAN clients
- [ ] External DNS (UDP 53) is blocked for non-Pi-hole sources
- [ ] Suricata EVE JSON output enabled
- [ ] Syslog forwarding to 192.168.40.10:514 enabled
- [ ] WireGuard tunnel configured and peer added
- [ ] Admin UIs only accessible from Management VLAN or WireGuard
- [ ] pfSense web interface on non-standard port
- [ ] SSH access restricted to Management VLAN

## Troubleshooting

### DNS Not Resolving
1. Check Pi-hole container is running: `docker ps | grep pihole`
2. Test from Docker host: `dig @172.28.1.2 google.com`
3. Check pfSense DNS forwarder points to 192.168.40.10
4. Verify firewall rule allows UDP 53 to 192.168.40.10

### No Syslog Received
1. Check rsyslog container: `docker logs shog-rsyslog`
2. Verify pfSense remote logging points to 192.168.40.10:514
3. Test from pfSense shell: `logger -n 192.168.40.10 -P 514 "test message"`
4. Check firewall allows UDP 514 from pfSense to Docker host

### Suricata Alerts Not in Wazuh
1. Verify EVE JSON output is single-line format
2. Check Filebeat logs: `docker logs shog-filebeat`
3. Confirm Wazuh indexer is healthy: `docker logs shog-wazuh-indexer`
4. Check index exists: `curl -k -u admin:password https://localhost:9200/_cat/indices`
