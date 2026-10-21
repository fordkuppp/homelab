# Ansible

Configuration layer for hosts that are not managed by Flux. Layout follows
[`docs/structure.md`](../docs/structure.md): inventory lives at the repo root,
roles and playbooks live here.

## tailscale-derp

Turns the Bangkok `edge` VPS into a custom Tailscale **DERP relay**. The
homelab sits behind CGNAT and advertises no reachable endpoints, so tailnet
peers can never connect directly and fall back to the Singapore public DERP --
slow and bandwidth-throttled. A relay on a public-IP VPS close to home becomes
the preferred path: both ends reach it directly, and it is un-throttled. It
still shows as `relay`, because only IPv6 or a public home IP give true direct,
but it is a fast, close, owned relay.

The box also runs `tailscaled` so derper can `--verify-clients` against the
tailnet (keeps the relay from being open to the world) and so the Caddy
gateway can reach homelab services over the tailnet. The VPS has **two public
IPs**: derper binds `:443` on the first (`derp_bind_ip`), Caddy binds `:443` on
the second (`caddy_bind_ip`), so each keeps its own Let's Encrypt cert with no
port collision. See [caddy-gateway](#caddy-gateway).

### 1. Get a tagged auth key

Create a **tagged** pre-auth key in the Tailscale admin console (reusable or
one-shot), store it in Bitwarden Secrets Manager, and declare its tag's
`tagOwners` in your tailnet policy. The private half is passed at run time and
never committed, mirroring the WireGuard key handling.

### 2. Point the inventory at the VPS

Set `ansible_host` for `derp-bkk-01` in `inventory/hosts.yaml`, and the real
`derp_hostname` / `derper_version` in `inventory/group_vars/edge.yaml`. The role
assumes a Debian or Ubuntu image with key-based root SSH. Create a DNS `A`
record for `derp_hostname` pointing at the VPS before running, so derper's
Let's Encrypt validation succeeds.

Tailscale ships no `derper` binary, so the role builds it from source **on the
controller** (your machine) and ships the static binary to the VPS -- keeping the
heavy compile off the tiny box. That means **Go must be installed locally**
(`go install tailscale.com/cmd/derper@<ver>` is what it runs). Target arch is
`derp_build_goarch` (default `amd64`).

### 3. Run it

```fish
cd ansible
ansible-playbook playbooks/tailscale-derp.yaml \
  -e "tailscale_authkey=$(bws secret get $BWS_TS_DERP_AUTHKEY_ID | jq -r .value)"
```

The final task prints the DNS record, the ports to open, and the `derpMap`
block to paste into your tailnet policy.

### Afterwards

- **Open the ports in the provider's cloud firewall**: `443/tcp` and `80/tcp`
  (ACME) for DERP-over-HTTPS, `3478/udp` for STUN. Same separate-layer caveat
  as vpn-exit -- a relay that looks healthy but is unreachable is almost always
  a closed security-group port.
- Add the printed `derpMap` region to the tailnet ACL (`OmitDefaultRegions:
  false` keeps the public DERPs as fallback).
- Verify from any client: `tailscale netcheck` should list your `bkk` region,
  and `tailscale ping <homelab-host>` should report `via DERP(bkk)` instead of
  `sin`.

### Scope

Relay only. Like vpn-exit, it does not harden the host (no SSH hardening, no
fail2ban, no default-deny firewall). Handle baseline hardening separately.

## caddy-gateway

Public reverse-proxy on the `edge` VPS's **second** IP. Because the homelab is
behind CGNAT, nothing at home is reachable from the internet directly; this is
how a service gets a public hostname. Caddy terminates HTTPS on `caddy_bind_ip`
and proxies to the homelab over the tailnet (the box is already a tailnet node
from `tailscale-derp`). Private, tailnet-only services like jellyfin do **not**
belong here -- reach those straight over Tailscale; only put internet-facing
hostnames in `caddy_sites`.

### 1. Second IP + the relay rebind

This role assumes the VPS has two public IPs. Set `derp_bind_ip` (first IP) and
`caddy_bind_ip` (second IP) in `inventory/group_vars/edge.yaml`. **Re-run
`tailscale-derp` first** so derper rebinds from "all interfaces" to the first
IP -- otherwise it still holds `:443` on the second IP and Caddy can't bind it.

### 2. Define the sites

Fill `caddy_sites` in `group_vars/edge.yaml`: each entry is a public `host`
(create an `A` record -> `caddy_bind_ip`) and an `upstream` the VPS can reach
over the tailnet. Use a tailnet `100.x` IP or a homelab LAN IP -- the latter
works because `tailscale_accept_routes: true` is set for this group. Upstreams
must be IPs, not MagicDNS names (this node runs with accept-dns off).

### 3. Run it

```fish
cd ansible
ansible-playbook playbooks/caddy-gateway.yaml
```

The Caddyfile is validated (`caddy validate`) before it is written, and Caddy
is reloaded only when it changes.

### Afterwards

- **Open `443/tcp` and `80/tcp` (ACME) on `caddy_bind_ip`** in the provider's
  cloud firewall -- same separate-layer caveat as the other playbooks.
- Caddy fetches a Let's Encrypt cert per site automatically on first request.
- Keep private services off the public IP: anything in `caddy_sites` is exposed
  to the internet.

### Scope

Reverse-proxy only. No host hardening, no auth/WAF in front of the proxied
services -- add those per service as needed.

## vpn-exit

Turns a rented VPS into a WireGuard exit node for the `media` namespace's
gluetun sidecar. The VPS does three jobs: terminate the tunnel, masquerade
outbound traffic, and DNAT the BitTorrent port back down the tunnel so inbound
peer connections reach qBittorrent.

### 1. Generate the client keypair

Do this on your workstation so the private half never touches the VPS:

```fish
wg genkey | tee client.key | wg pubkey
```

- Private key (`client.key`) goes into Bitwarden Secrets Manager as
  `wireguard_client_private_key`. The `media` namespace reads it through an
  ExternalSecret.
- Public key (the command's output) goes into
  `inventory/group_vars/vpn_exit.yaml` as `wg_client_public_key`.

Delete `client.key` once it is in Bitwarden.

### 2. Point the inventory at the VPS

Set `ansible_host` in `inventory/hosts.yaml`. The role assumes a Debian or
Ubuntu image with key-based root SSH.

### 3. Run it

```fish
cd ansible
ansible-playbook playbooks/vpn-exit.yaml
```

The final task prints the gluetun environment for the qBittorrent pod,
including the server public key the role generated.

### Afterwards

- **Open the ports in the provider's cloud firewall** as well as on the host:
  UDP `51820` for the tunnel and TCP+UDP `51413` for peers. Security-group
  rules are a separate layer from the iptables rules this role installs and are
  the usual reason a tunnel that looks healthy never completes a handshake.
- Verify from the VPS with `wg show`. A peer with a recent handshake and
  non-zero transfer means gluetun is connected.
- Confirm the exit IP from inside the pod:
  `kubectl -n media exec deploy/qbittorrent -c gluetun -- wget -qO- ifconfig.me`

### Scope

This role configures the tunnel only. It does not harden the host: no SSH
hardening, no fail2ban, no default-deny firewall policy. A fresh VPS with
password SSH enabled is exposed from the moment it boots, so handle baseline
hardening before or alongside this.

### gluetun side

**Not currently wired up.** qBittorrent runs without a tunnel, on the home IP,
by choice. The VPS role below still works; this section is what to add back
when the tunnel is wanted.

Add `secrets.yaml` to `kubernetes/apps/media/` and re-list it in that
directory's `kustomization.yaml`:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: gluetun-wireguard
  namespace: media
spec:
  refreshInterval: 1h0m0s
  secretStoreRef:
    name: bitwarden-secretsmanager
    kind: ClusterSecretStore
  data:
    - secretKey: WIREGUARD_PRIVATE_KEY
      remoteRef:
        key: wireguard_client_private_key
    - secretKey: WIREGUARD_PUBLIC_KEY
      remoteRef:
        key: wireguard_server_public_key
    - secretKey: WIREGUARD_ENDPOINT_IP
      remoteRef:
        key: wireguard_endpoint_ip
```

Then add gluetun as the first container in the qBittorrent pod. Containers in
a pod share one network namespace, so qBittorrent needs no VPN config of its
own -- it simply sees a stack whose default route is the tunnel:

```yaml
dnsPolicy: None
dnsConfig:
  nameservers:
    - 127.0.0.1
containers:
  - name: gluetun
    image: qmcgaw/gluetun:v3.41.3
    securityContext:
      capabilities:
        add: [NET_ADMIN]
    env:
      - {name: VPN_SERVICE_PROVIDER, value: custom}
      - {name: VPN_TYPE, value: wireguard}
      - {name: WIREGUARD_ENDPOINT_PORT, value: "51820"}
      - {name: WIREGUARD_ADDRESSES, value: 10.13.13.2/32}
      - {name: WIREGUARD_PERSISTENT_KEEPALIVE_INTERVAL, value: 25s}
      - {name: FIREWALL_OUTBOUND_SUBNETS, value: 10.42.0.0/16,10.43.0.0/16}
      - {name: FIREWALL_INPUT_PORTS, value: "8080"}
      - {name: FIREWALL_VPN_INPUT_PORTS, value: "51413"}
    envFrom:
      - secretRef: {name: gluetun-wireguard}
    volumeMounts:
      - {name: tun, mountPath: /dev/net/tun}
volumes:
  - name: tun
    hostPath:
      path: /dev/net/tun
      type: CharDevice
```

Four things that are easy to get wrong:

- `FIREWALL_OUTBOUND_SUBNETS` must list the pod and service CIDRs. The
  killswitch denies everything that is not tunnel traffic, replies to
  in-cluster callers included, so without it Sonarr and Radarr cannot reach
  qBittorrent's API and the WebUI is unreachable through the gateway. It must
  also not overlap the 10.13.13.0/24 tunnel range.
- `WIREGUARD_PERSISTENT_KEEPALIVE_INTERVAL` matters because the VPS can never
  initiate. Without it the NAT mapping at the home router expires and inbound
  peers stop arriving a few minutes after the last transfer.
- `dnsPolicy: None` points the pod at gluetun's own DoT resolver so tracker
  lookups stay inside the tunnel. Safe only because the endpoint is an IP
  literal, so gluetun needs no DNS to start. Side effect: if gluetun is down,
  nothing in that pod resolves.
- `FIREWALL_VPN_INPUT_PORTS` is the tunnel-side allow for inbound peers
  arriving via the VPS DNAT rule. `FIREWALL_INPUT_PORTS` is the LAN-side one
  for the WebUI.
