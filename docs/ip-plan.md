# IP Plan

## Overview

- LAN subnet: `192.168.1.0/24`
- Gateway/router: `192.168.1.1`
- DHCP range (router-managed): `192.168.1.100–192.168.1.200`

## Reserved Ranges (Static)

> These ranges are conventions to keep things predictable. Adjust as needed, but avoid overlapping DHCP.

### Network infrastructure
- `192.168.1.2–192.168.1.9`
- `192.168.1.2` — Technitium DNS
- `192.168.1.3` — Envoy Gateway (LAN)

### Homelab infrastructure (Proxmox, Truenas)
- `192.168.1.10–192.168.1.19`

### Kubernetes cluster node
- `192.168.1.20–192.168.1.29`

### Komodo docker
- `192.168.1.30–192.168.1.39`

### Metallb
- `192.168.1.40–192.168.1.59`

### IoT
- `192.168.1.60–192.168.1.99`
- `192.168.1.60` — LG TV (Router managed)
- `192.168.1.61` - Elegoo (Router managed)
