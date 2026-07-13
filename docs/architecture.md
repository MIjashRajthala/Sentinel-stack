# SHOG Architecture

## Network Architecture

```
                              INTERNET
                                 |
                    +------------+------------+
                    |    ISP Router/Modem     |
                    |  (Bridge mode ideally)  |
                    +------------+------------+
                                 |  Public IP (DHCP/PPPoE)
                                 |
                    +============+============+
                    ||                       ||
                    ||     pfSense CE        ||  <-- BARE METAL or VM
                    ||    ==============     ||      (NOT Docker)
                    ||    Network Gateway    ||
                    ||    ==============     ||
                    ||                       ||
                    ||  +-----------------+  ||
                    ||  | Suricata IDS    |  ||   EVE JSON logs
                    ||  | (inline/legacy) |  ||   -> rsyslog
                    ||  +-----------------+  ||
                    ||  +-----------------+  ||
                    ||  | DHCP Server     |  ||   192.168.10.0/24 (LAN)
                    ||  +-----------------+  ||   192.168.20.0/24 (Users)
                    ||  +-----------------+  ||   192.168.30.0/24 (IoT)
                    ||  | VLAN 10 Mgmt    |  ||   192.168.40.0/24 (Servers)
                    ||  | VLAN 20 Users   |  ||
                    ||  | VLAN 30 IoT     |  ||
                    ||  | VLAN 40 Srv     |  ||
                    ||  +-----------------+  ||
                    ||  +-----------------+  ||
                    ||  | WireGuard VPN   |  ||   10.200.200.0/24
                    ||  +-----------------+  ||
                    ||  +-----------------+  ||
                    ||  | Syslog Forward  |  ||   -> Docker:514/udp
                    ||  +-----------------+  ||
                    ||  +-----------------+  ||
                    ||  | DNS Forwarder   |  ||   -> Pi-hole:53
                    ||  +-----------------+  ||
                    ||                       ||
                    ++=+=+=+=+=+=+=+=+=+=+=+=++
                       |         |         |
              +--------+         |         +---------+
              |                  |                   |
    +---------v---------+  +----v-----+    +--------v--------+
    |  VLAN 10          |  | VLAN 20  |    | VLAN 40         |
    |  Management       |  | Users    |    | Servers/Docker  |
    |  192.168.10.0/24  |  |192.168.20|    | 192.168.40.0/24 |
    |                   |  |          |    |                 |
    | Admin workstation |  | Laptops  |    | Ubuntu Docker   |
    | (SSH/https only)  |  | Phones   |    | Host            |
    +-------------------+  +----------+    |                 |
                                           | +-------------+ |
                                           | | Docker Eng. | |
                                           | +------+------+ |
                                           |        |        |
                                           |  +-----v------+ |
                                           |  | br-shog-*  | |
                                           |  |  Networks  | |
                                           |  +-----+------+ |
                                           |        |        |
                                           |  +-----v-----+  |
                                           |  | Containers|  |
                                           |  +-----------+  |
                                           |                 |
                                           +-----------------+
```

## pfSense to Docker Host — Physical/Logical Connections

```
    pfSense LAN port (igb1/vmx1)
            |
            |  192.168.40.1/24 (VLAN 40 gateway)
            +-------------------------------------------+
                                                        |
                                            +-----------v-----------+
                                            |   Ubuntu Server       |
                                            |   (Docker Host)       |
                                            |   192.168.40.10/24    |
                                            |   Gateway: 192.168.40.1|
                                            +-----------+-----------+
                                                        |
                                            +-----------v-----------+
                                            |   br-shog-mgmt        |  172.27.1.0/24
                                            |   br-shog-sec         |  172.28.1.0/24
                                            |   br-shog-mon         |  172.29.1.0/24 (internal)
                                            +-----------------------+
```

## Docker Network Segmentation

```
    +------------------+      +------------------+      +------------------+
    |   Management     |      |    Security      |      |   Monitoring     |
    |   172.27.1.0/24  |      |   172.28.1.0/24  |      |   172.29.1.0/24  |
    |                  |      |                  |      |  (no external    |
    | Portainer   .2   |      | Pi-hole     .2   |      |   gateway)       |
    | Uptime Kuma .3   |      | Unbound     .3   |      |                  |
    |                  |      | rsyslog     .4   |      | Pi-hole     .2   |
    |  +  MANAGEMENT_IP|      | CrowdSec    .5   |      | rsyslog     .4   |
    |    bound ports   |      | Wazuh Idx   .10  |      | CrowdSec    .5   |
    |   (host iface)   |      | Wazuh Mgr   .11  |      | Wazuh Mgr   .11  |
    |                  |      | Wazuh Dash  .12  |      | Wazuh Dash  .12  |
    |                  |      | Wazuh Agent .13  |      | Portainer   .3   |
    |                  |      | Filebeat    .15  |      | Uptime Kuma .6   |
    |                  |      | (OpenCTI)   .20+ |      | Alerting    .7   |
    +------------------+      +------------------+      +------------------+
           |                           |                        |
           |          Host firewall restricts access             |
           |          to MANAGEMENT_IP only for admin UIs        |
           +---------------------------+------------------------+
                                       |
                               Docker Host
```

## Data Flow Diagram

```
    LAN Clients                         SHOG Stack
    +---------+                        +-----------+
    | Device  |--(1) DNS Query-------->|  Pi-hole  |
    | (user)  |                        |  :53      |
    +---------+                        +-----+-----+
                                             |
                                             | (2) Recursive query
                                             v
                                       +-----------+
                                       |  Unbound  |
                                       |  :5335    |
                                       +-----+-----+
                                             |
                                             | (3) Root server resolution
                                             v
                                       +-----------+
                                       |  Internet |
                                       |  DNS      |
                                       +-----------+

    pfSense                            SHOG Stack
    +---------+                        +-----------+
    |Firewall |--(4) Syslog----------->|  rsyslog  |
    | Logs    |    UDP 514             |  :514     |
    +---------+                        +-----+-----+
                                             |
                                             | (5) Read log files
                                             v
                                       +-----------+
                                       | Filebeat  |
                                       +-----+-----+
                                             |
                                             | (6) Ingest
                                             v
                                       +-----------+
                                       | Wazuh     |
                                       | Indexer   |
                                       | :9200     |
                                       +-----+-----+
                                             ^
                                             | (7) Query/Index
    +---------+                        +-----------+
    | Suricata|--(8) EVE JSON-------->|  Wazuh    |
    | Alerts  |    (via syslog)       |  Manager  |
    +---------+                        +-----+-----+
                                             |
                                             | (9) Alerts
                                             v
                                       +-----------+
                                       | Wazuh     |
                                       | Dashboard |
                                       | :5601     |
                                       +-----------+

    Docker Host                        SHOG Stack
    +---------+                        +-----------+
    | Host FS |--(10) Audit/FIM------>| Wazuh     |
    | Events  |                        | Agent     |
    +---------+                        +-----+-----+
                                             |
                                             | (11) Forward
                                             v
                                       +-----------+
                                       | Wazuh     |
                                       | Manager   |
                                       +-----------+

    Any Container                      SHOG Stack
    +---------+                        +-----------+
    | Logs    |--(12) Docker API----->| CrowdSec  |
    |         |    (read-only)        |           |
    +---------+                        +-----+-----+
                                             |
                                             | (13) Decision
                                             v
                                       +-----------+
                                       | CrowdSec  |
                                       | Bouncer   |
                                       | (iptables)|
                                       +-----------+
```

## Component Inventory

| # | Component | Image | Version | Purpose | Data Volume |
|---|-----------|-------|---------|---------|-------------|
| 1 | unbound | mvance/unbound | 1.19.0 | Recursive DNS | unbound-data |
| 2 | pihole | pihole/pihole | 2024.02.2 | DNS filtering | pihole-etc, pihole-dnsmasq |
| 3 | rsyslog | rsyslog/syslog_appliance_alpine | 8.2310.0 | Log receiver | rsyslog-data, rsyslog-spool |
| 4 | crowdsec | crowdsecurity/crowdsec | v1.6.0 | Threat detection | crowdsec-config, crowdsec-data |
| 5 | crowdsec-bouncer | crowdsecurity/iptables-bouncer | v0.0.28 | IP blocking | crowdsec-bouncer-* |
| 6 | wazuh-indexer | wazuh/wazuh-indexer | 4.7.2 | Search/Analytics | wazuh-indexer-data |
| 7 | wazuh-manager | wazuh/wazuh-manager | 4.7.2 | SIEM engine | wazuh-manager-var-ossec |
| 8 | wazuh-dashboard | wazuh/wazuh-dashboard | 4.7.2 | Web UI | wazuh-dashboard-data |
| 9 | wazuh-agent | wazuh/wazuh-agent | 4.7.2 | Host telemetry | wazuh-agent-var-ossec |
| 10 | portainer | portainer/portainer-ce | 2.19.4 | Container mgmt | portainer-data |
| 11 | uptime-kuma | louislam/uptime-kuma | 1.23.11 | Monitoring | uptime-kuma-data |
| 12 | filebeat | docker.elastic.co/beats/filebeat-oss | 8.11.4 | Log shipper | filebeat-data, filebeat-logs |
| 13 | alerting | ghcr.io/containrrr/shoutrrr | 0.8.0 | Notifications | alerting-data |
| 14 | opencti-platform | opencti/platform | 6.0.0 | Threat intel | opencti-data |
| 15 | opencti-redis | redis | 7.2.4-alpine | Cache | opencti-redis-data |
| 16 | opencti-elasticsearch | docker.elastic.co/elasticsearch/elasticsearch | 8.11.4 | Search | opencti-es-data |
| 17 | opencti-minio | minio/minio | RELEASE.2024-01 | Object store | opencti-minio-data |
| 18 | opencti-rabbitmq | rabbitmq | 3.12.13-mgmt-alpine | Message queue | opencti-rabbitmq-data |

## Port Matrix

| Service | Container Port | Host Binding | Description |
|---------|---------------|--------------|-------------|
| Unbound | 53/tcp, 53/udp | 127.0.0.1:5335 | Recursive DNS (localhost only) |
| Pi-hole DNS | 53/tcp, 53/udp | 0.0.0.0:53 | DNS for LAN clients |
| Pi-hole Web | 80/tcp | MANAGEMENT_IP:8080 | Admin UI |
| rsyslog | 514/tcp, 514/udp | 0.0.0.0:514 | Syslog from pfSense |
| Wazuh Dashboard | 5601/tcp | MANAGEMENT_IP:5601 | SIEM web UI |
| Portainer | 9443/tcp, 9000/tcp | MANAGEMENT_IP:9443/9000 | Docker mgmt |
| Uptime Kuma | 3001/tcp | MANAGEMENT_IP:3001 | Monitoring UI |
| OpenCTI | 8080/tcp | MANAGEMENT_IP:8088 | Threat intel (optional) |

**Internal-only ports** (not exposed to host): Wazuh Indexer :9200, Wazuh Manager :1514/:55000, CrowdSec :8080, Redis :6379, RabbitMQ :5672, MinIO :9000.

## Audit Data Flow Summary

| Source | Log Type | Transport | Destination | Retention |
|--------|----------|-----------|-------------|-----------|
| pfSense firewall | Filter logs | Syslog UDP/514 | rsyslog -> Filebeat -> Wazuh | 90 days (configurable) |
| Suricata | EVE JSON | Syslog TCP/514 | rsyslog -> Filebeat -> Wazuh | 90 days |
| Docker host | Auth, kernel, FIM | Wazuh agent | Wazuh Manager -> Indexer | 90 days |
| Docker containers | Container logs | Docker API (read-only) | CrowdSec analysis + host journal | 30 days |
| Pi-hole | DNS queries | Local SQLite | Pi-hole database (90 days) | 90 days |
| CrowdSec | Threat detections | Local + API | CrowdSec database + console | 30 days |
