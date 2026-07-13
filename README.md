# Secure Home-Office Gateway (SHOG)

A reproducible, open-source defensive security platform for home offices and small teams. Deploy a complete SIEM, DNS filtering, threat detection, and monitoring stack with one command.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Docker Compose](https://img.shields.io/badge/Docker%20Compose-3.8+-blue.svg)](https://docs.docker.com/compose/)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04%2B-orange.svg)](https://ubuntu.com/)

---

## Architecture Overview

```
                     +-----------------------------+
                     |      INTERNET / ISP         |
                     +-------------+---------------+
                                   |
                     +-------------v---------------+
                     |   ISP Router / Modem        |
                     |   (Bridge/Pass-through      |
                     |    mode recommended)        |
                     +-------------+---------------+
                                   | WAN
                     +-------------v---------------+
                     |                             |
                     |      pfSense CE             |  <-- NOT in Docker
                     |      (Bare Metal / VM)      |      Edge Firewall/Router
                     |                             |
                     |  - Suricata IDS             |
                     |  - DHCP Server              |
                     |  - DNS Forwarder -> Pi-hole |
                     |  - Firewall Rules           |
                     |  - WireGuard VPN            |
                     |  - VLAN Routing             |
                     |  - Syslog Forwarding        |
                     |                             |
                     +--+-----------+--------------+
                        |           | LAN
           +------------+           +-----------------+
           |                                          |
    +------v------+                         +---------v---------+
    | Management  |                         |  Protected LAN    |
    |  VLAN 10    |                         |  (User devices)   |
    |             |                         |                   |
    | Admin only  |                         |  VLAN 20, 30, 40  |
    +------+------+                         +---------+---------+
           |                                          |
           |  +---------------------------------------+
           |  |
    +------v--v------------------------------------------+
    |                                                    |
    |        Ubuntu Server — Docker Host                 |
    |                                                    |
    |  +----------------+  +----------------+           |
    |  | Portainer CE   |  | Wazuh Stack    |           |
    |  | :9443          |  | (SIEM) :5601   |           |
    |  +----------------+  +----------------+           |
    |  +----------------+  +----------------+           |
    |  | Pi-hole        |  | CrowdSec       |           |
    |  | DNS :53        |  | Threat Det.    |           |
    |  +----------------+  +----------------+           |
    |  +----------------+  +----------------+           |
    |  | Unbound        |  | Uptime Kuma    |           |
    |  | DNS Recursor   |  | Monitor :3001  |           |
    |  +----------------+  +----------------+           |
    |  +----------------+  +----------------+           |
    |  | rsyslog        |  | Wazuh Agent    |           |
    |  | Log Receiver   |  | Host telemetry |           |
    |  +----------------+  +----------------+           |
    |                                                    |
    +----------------------------------------------------+
```

**Key principle**: pfSense is the network gateway and stays **outside Docker**. All other services run as containers on an Ubuntu Docker host behind pfSense.

---

## Quick Start

### Prerequisites

| Resource | Minimum | Recommended | Advanced |
|----------|---------|-------------|----------|
| CPU | 2 cores | 4 cores | 6+ cores |
| RAM | 4 GB | 8 GB | 16+ GB |
| Disk | 50 GB SSD | 100 GB SSD | 200 GB+ NVMe |
| Network | 1 NIC | 2 NICs (pfSense) | Managed switch + VLANs |
| OS | Ubuntu 22.04 LTS | Ubuntu 24.04 LTS | Ubuntu 24.04 LTS |

### One-Command Install

```bash
# 1. Clone the repository
git clone https://github.com/your-org/shog.git && cd shog

# 2. Run the installer
./install.sh
```

The installer will:
- Run preflight checks (OS, Docker, RAM, ports, kernel params)
- Create `.env` from `.env.example` if absent
- Generate strong random secrets
- Pull all container images
- Start the stack and verify health

### Post-Install

1. **Configure pfSense** using the guide at [`docs/pfsense-setup.md`](docs/pfsense-setup.md)
2. **Access dashboards** (from management subnet only):
   - Portainer: `https://MANAGEMENT_IP:9443`
   - Wazuh: `https://MANAGEMENT_IP:5601`
   - Uptime Kuma: `http://MANAGEMENT_IP:3001`
   - Pi-hole: `http://MANAGEMENT_IP:8080/admin`

---

## What's Included

| Service | Purpose | Network |
|---------|---------|---------|
| **pfSense CE** | Edge firewall, IDS, VPN, DHCP, VLANs | Physical/VM |
| **Portainer CE** | Docker management UI | Management |
| **Pi-hole** | DNS filtering, ad/tracker blocking | Security |
| **Unbound** | Recursive DNS resolver (root servers) | Security |
| **Wazuh** | SIEM: Manager + Indexer + Dashboard | Security |
| **Wazuh Agent** | Host telemetry (Docker host) | Security |
| **rsyslog** | Central syslog receiver (pfSense/Suricata) | Security |
| **Filebeat** | Log shipper to Wazuh Indexer | Security |
| **CrowdSec** | Behavioural threat detection + bouncer | Security |
| **Uptime Kuma** | Service availability monitoring | Management |
| **OpenCTI** *(opt)* | Threat intelligence platform | Security |
| **Alerting** *(opt)* | Webhook/email notifications | Monitoring |

---

## Security Features

- **Network segmentation**: Three isolated Docker networks (management, security, monitoring)
- **No exposed internals**: Databases and indexers not reachable from LAN
- **Admin UIs bound to `MANAGEMENT_IP`**: Not accessible from general LAN
- **Auto-generated secrets**: No hardcoded passwords
- **Security headers**: CSP, HSTS, X-Frame-Options where supported
- **Least privilege**: Dropped capabilities, read-only mounts, `no-new-privileges`
- **Health checks**: All services with automatic restart
- **Log rotation**: Persistent logs with size-based rotation
- **Image pinning**: All images pinned to specific versions
- **Backup/restore**: Included scripts and documentation

---

## Profiles (Optional Services)

| Profile | Command | Description |
|---------|---------|-------------|
| `alerting` | `docker compose --profile alerting up -d` | Discord/Slack/email alerts |
| `opencti` | `docker compose --profile opencti up -d` | Threat intel platform (8GB+ extra RAM) |
| `host-bouncer` | `docker compose --profile host-bouncer up -d` | CrowdSec iptables bouncer on host |

---

## Repository Structure

```
shog/
├── docker-compose.yml              # Main stack definition
├── compose.override.example.yml    # Override template
├── .env.example                    # Configuration template
├── install.sh                      # One-command installer
├── uninstall.sh                    # Removal with warnings
├── configs/                        # Service configurations
│   ├── unbound/
│   ├── pihole/
│   ├── rsyslog/
│   ├── crowdsec/
│   └── wazuh/
├── scripts/
│   ├── preflight-check.sh          # System validation
│   ├── generate-secrets.sh         # Secret generation
│   ├── backup.sh                   # Backup all data
│   └── health-check.sh             # Service health monitor
├── docs/
│   ├── architecture.md             # Architecture & ASCII diagrams
│   ├── pfsense-setup.md            # pfSense configuration
│   ├── threat-model.md             # Threat model & controls
│   ├── evaluation-plan.md          # Testing & metrics
│   ├── security-hardening.md       # Hardening guide
│   ├── troubleshooting.md          # Common issues
│   └── restore.md                  # Restore procedures
└── logs/                           # Runtime logs (created)
    └── backups/                    # Backups (created)
```

---

## Documentation

| Document | Purpose |
|----------|---------|
| [`docs/architecture.md`](docs/architecture.md) | Full architecture, data flow, network diagram |
| [`docs/pfsense-setup.md`](docs/pfsense-setup.md) | pfSense WAN/LAN/VLAN, DHCP, DNS, Suricata, WireGuard |
| [`docs/threat-model.md`](docs/threat-model.md) | Assets, threat actors, attack paths, controls, residual risk |
| [`docs/evaluation-plan.md`](docs/evaluation-plan.md) | Testing plan, metrics, SUS questionnaire |
| [`docs/security-hardening.md`](docs/security-hardening.md) | Additional hardening beyond defaults |
| [`docs/troubleshooting.md`](docs/troubleshooting.md) | Common problems and solutions |
| [`docs/restore.md`](docs/restore.md) | Disaster recovery procedures |

---

## License

MIT License — See [LICENSE](LICENSE) for details.

**Disclaimer**: This is a defensive security research and education project. No warranty is provided. Review all configurations before production deployment. pfSense is a registered trademark of Netgate.
