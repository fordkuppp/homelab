# IP Plan

## Overview

- LAN subnet: `192.168.1.0/24`
- Gateway/router: `192.168.1.1`
- DHCP range (router-managed): `192.168.1.60–192.168.1.200`
  - Pool starts at `.60` (rather than `.100`) because the current router only allows reservations inside the DHCP pool (fk you ais)

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

## DNS Resolution

`*.local.fordkuppp.me` resolves to `192.168.1.3` from **everywhere** — one
answer, two paths to it. No split-horizon.

| Source | Record | Notes |
| --- | --- | --- |
| Cloudflare (public zone) | `*.local.fordkuppp.me A 192.168.1.3` | Static, hand-managed, proxy off |
| Technitium (`local.fordkuppp.me`) | per-host A → `192.168.1.3` | Written by `external-dns-local` over RFC2136 |

Reaching `192.168.1.3`:

- **On the LAN** — direct to the Envoy Gateway MetalLB address.
- **Off the LAN** — Tailscale subnet route, advertised by the `Connector` in
  `kubernetes/apps/tailscale/connector.yaml` as `192.168.1.3/32` and
  `192.168.1.2/32`. Deliberately /32s, not `192.168.1.0/24`, which would
  hijack that range on any foreign network using it.

Both resolvers return the same address, so a device's DNS choice (Android
Private DNS, browser DoH, MagicDNS) no longer decides whether apps are
reachable. See `docs/runbooks/dns-single-answer.md`.
