# SHOG Architecture

## Network Architecture

```mermaid
flowchart TB
    internet(["Internet"]) --> router["ISP Router / Modem<br/>Bridge mode preferred"]
    router -->|"Public IP (DHCP / PPPoE)"| gateway

    subgraph pfsense["pfSense CE — Network Gateway<br/>(bare metal or VM; not Docker)"]
        direction TB
        gateway["Gateway / Firewall"]
        suricata["Suricata IDS<br/>(inline / legacy)"]
        dhcp["DHCP Server"]
        vlans["VLAN Routing"]
        vpn["WireGuard VPN<br/>10.200.200.0/24"]
        syslog["Syslog Forwarder"]
        dns["DNS Forwarder"]

        gateway --> suricata
        gateway --> dhcp
        gateway --> vlans
        gateway --> vpn
        gateway --> syslog
        gateway --> dns
        suricata -->|"EVE JSON logs"| syslog
    end

    vlans --> vlan10node
    vlans --> vlan20node
    vlans --> vlan30node
    vlans --> dockerHost

    subgraph vlan10["VLAN 10 — Management<br/>192.168.10.0/24"]
        vlan10node["Admin workstation<br/>SSH / HTTPS only"]
    end

    subgraph vlan20["VLAN 20 — Users<br/>192.168.20.0/24"]
        vlan20node["Laptops and phones"]
    end

    subgraph vlan30["VLAN 30 — IoT<br/>192.168.30.0/24"]
        vlan30node["IoT devices"]
    end

    subgraph vlan40["VLAN 40 — Servers / Docker<br/>192.168.40.0/24"]
        direction TB
        dockerHost["Ubuntu Docker Host"] --> engine["Docker Engine"]
        engine --> networks["br-shog-* networks"]
        networks --> containers["Containers"]
        rsyslog["rsyslog<br/>:514/udp"]
        pihole["Pi-hole<br/>:53"]
    end

    syslog -->|"Docker :514/udp"| rsyslog
    dns -->|"Pi-hole :53"| pihole
```

## pfSense to Docker Host — Physical/Logical Connections

```mermaid
flowchart LR
    pfsense["pfSense LAN port<br/>igb1 / vmx1"]
    ubuntu["Ubuntu Server — Docker Host<br/>192.168.40.10/24<br/>Gateway: 192.168.40.1"]
    bridges["Docker bridge networks<br/>br-shog-mgmt — 172.27.1.0/24<br/>br-shog-sec — 172.28.1.0/24<br/>br-shog-mon — 172.29.1.0/24 (internal)"]

    pfsense -->|"VLAN 40 gateway<br/>192.168.40.1/24"| ubuntu
    ubuntu --> bridges
```

## Docker Network Segmentation

```mermaid
flowchart TB
    admin(["Admin traffic"]) -->|"MANAGEMENT_IP only"| firewall{"Host firewall"}

    subgraph management["Management — 172.27.1.0/24"]
        management_services["Portainer — .2<br/>Uptime Kuma — .3<br/><br/>Admin UI ports bound to MANAGEMENT_IP"]
    end

    subgraph security["Security — 172.28.1.0/24"]
        security_services["Pi-hole — .2<br/>Unbound — .3<br/>rsyslog — .4<br/>CrowdSec — .5<br/>Wazuh Indexer — .10<br/>Wazuh Manager — .11<br/>Wazuh Dashboard — .12<br/>Wazuh Agent — .13<br/>Filebeat — .15<br/>OpenCTI — .20+"]
    end

    subgraph monitoring["Monitoring — 172.29.1.0/24<br/>(no external gateway)"]
        monitoring_services["Pi-hole — .2<br/>rsyslog — .4<br/>CrowdSec — .5<br/>Wazuh Manager — .11<br/>Wazuh Dashboard — .12<br/>Portainer — .3<br/>Uptime Kuma — .6<br/>Alerting — .7"]
    end

    firewall --> management_services
    management_services --> docker["Docker Host"]
    security_services --> docker
    monitoring_services --> docker
```

## Data Flow Diagram

```mermaid
flowchart LR
    subgraph sources["Event and Query Sources"]
        direction TB
        device["LAN client device"]
        firewall["pfSense firewall logs"]
        suricata["Suricata alerts"]
        hostfs["Docker host filesystem events"]
        containerlogs["Container logs"]
    end

    subgraph shog["SHOG Stack"]
        direction TB
        pihole["Pi-hole<br/>:53"]
        unbound["Unbound<br/>:5335"]
        internetdns["Internet DNS"]
        rsyslog["rsyslog<br/>:514"]
        filebeat["Filebeat"]
        indexer["Wazuh Indexer<br/>:9200"]
        manager["Wazuh Manager"]
        dashboard["Wazuh Dashboard<br/>:5601"]
        agent["Wazuh Agent"]
        crowdsec["CrowdSec"]
        bouncer["CrowdSec Bouncer<br/>(iptables)"]
    end

    device -->|"(1) DNS query"| pihole
    pihole -->|"(2) Recursive query"| unbound
    unbound -->|"(3) Root server resolution"| internetdns

    firewall -->|"(4) Syslog — UDP 514"| rsyslog
    rsyslog -->|"(5) Read log files"| filebeat
    filebeat -->|"(6) Ingest"| indexer
    manager -->|"(7) Query / index"| indexer
    suricata -->|"(8) EVE JSON via syslog"| manager
    manager -->|"(9) Alerts"| dashboard

    hostfs -->|"(10) Audit / FIM"| agent
    agent -->|"(11) Forward"| manager

    containerlogs -->|"(12) Docker API — read-only"| crowdsec
    crowdsec -->|"(13) Decision"| bouncer
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
| 11 | uptime-kuma | louislam/uptime-kuma | 2.3.2 | Monitoring | uptime-kuma-data |
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
