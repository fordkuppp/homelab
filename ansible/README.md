# Ansible

Configuration layer for hosts that are not managed by Flux. Layout follows
[`docs/structure.md`](../docs/structure.md): inventory lives at the repo root,
roles and playbooks live here. Per-concern playbooks sit at `playbooks/`;
composite (whole-machine) playbooks that chain them live in `playbooks/composite/`.

## Provision the whole edge box

`composite/edge.yaml` runs the full stack on the `edge` group in order --
baseline hardening, the DERP relay, then the gateway (which no-ops until
`caddy_sites` or `caddy_l4_routes` is set):

```fish
cd ansible
ansible-playbook playbooks/composite/edge.yaml \
  -e "tailscale_authkey=$(bws secret get $BWS_TS_DERP_AUTHKEY_ID | jq -r .value)"
```

It uses `import_playbook`, so each concern (`baseline.yaml`, `tailscale-derp.yaml`,
`caddy-gateway.yaml`) stays runnable on its own too.

## Provision the whole Wings VM

`composite/wings.yaml` runs the same three-stage shape on the `games` group --
baseline hardening, then tailscaled, then Wings:

```fish
cd ansible
ansible-playbook playbooks/composite/wings.yaml \
  -e "tailscale_authkey=$(bws secret get $BWS_TS_GAMES_AUTHKEY_ID | jq -r .value)" \
  -e "pelican_node_uuid=$(bws secret get $BWS_PELICAN_NODE_UUID_ID | jq -r .value)" \
  -e "pelican_node_token_id=$(bws secret get $BWS_PELICAN_NODE_TOKEN_ID_ID | jq -r .value)" \
  -e "pelican_node_token=$(bws secret get $BWS_PELICAN_NODE_TOKEN_ID | jq -r .value)"
```

The node credentials come from the Panel and must exist first -- the Panel
generates them when you create the Node, and there is no API to bootstrap them.
See [`docs/runbooks/pelican.md`](../docs/runbooks/pelican.md).

## baseline

Key-only SSH (`PasswordAuthentication no`, root `prohibit-password`),
conffile-safe unattended security upgrades (`--force-confdef --force-confold`
on all apt ops, so an upgrade can't wedge dpkg the way the cloud-init prompt
did during provisioning), and a fail2ban sshd jail. For the internet-facing
`edge` box. SSH stays on **public `:22`, key-only** by default -- flip the
`baseline_*` vars to change password/root policy or drop fail2ban, and restrict
`:22` to the tailnet via the provider firewall if you want tailnet-only access.

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
gateway can reach homelab services over the tailnet. That install is **not** in
this role -- it lives in `tailscale_node`, which `tailscale_derp` pulls in as a
meta dependency, so the Wings host can reuse it. The VPS has **two public
IPs**: derper binds `:443` on the first (`derp_bind_ip`), Caddy binds `:443` on
the second (`caddy_bind_ip`), so each keeps its own Let's Encrypt cert with no
port collision. See [caddy-gateway](#caddy-gateway).

### 1. Get a tagged auth key

Create a **tagged** pre-auth key in the Tailscale admin console (reusable or
one-shot), store it in Bitwarden Secrets Manager, and declare its tag's
`tagOwners` in your tailnet policy. The private half is passed at run time and
never committed.

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
  (ACME) for DERP-over-HTTPS, `3478/udp` for STUN. The firewall is a layer
  separate from the host -- a relay that looks healthy but is unreachable is
  almost always a closed security-group port.
- Add the printed `derpMap` region to the tailnet ACL (`OmitDefaultRegions:
  false` keeps the public DERPs as fallback).
- Verify from any client: `tailscale netcheck` should list your `bkk` region,
  and `tailscale ping <homelab-host>` should report `via DERP(bkk)` instead of
  `sin`.

### Scope

Relay only. It does not harden the host (no SSH hardening, no fail2ban, no
default-deny firewall). Handle baseline hardening separately.

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

### 3. Forward raw TCP with `caddy_l4_routes`

HTTP reverse-proxying is not enough for a game server: Minecraft speaks its own
protocol on `25565/tcp`. Upstream Caddy has no layer-4 proxy, so the role builds
Caddy **from source on the controller** with
[`caddy-l4`](https://github.com/mholt/caddy-l4) compiled in -- the same
build-locally-ship-the-binary approach as `derper`, and the same **Go must be
installed locally** requirement. `caddy_version` and `caddy_l4_version` are
pinned and Renovate-tracked; the built artifact is version-stamped, so a repeat
run at the same versions skips the compile entirely.

Each `caddy_l4_routes` entry is a `listen_port` and an `upstream`:

```yaml
caddy_l4_routes:
  - listen_port: 25565
    upstream: "100.x.y.z:25565" # the Wings host's tailnet address
```

Layer-4 listeners do not inherit `default_bind`, so the role writes
`{{ caddy_bind_ip }}:{{ listen_port }}` explicitly -- without that, Caddy would
also claim the port on derper's IP.

There is no PROXY protocol here: Fabric and Forge cannot read it, so the server
sees every player arriving from the gateway's IP. **Ban by UUID, not by IP.**

### 4. Run it

```fish
cd ansible
ansible-playbook playbooks/caddy-gateway.yaml
```

The Caddyfile is validated (`caddy validate`, using the custom binary) before it
is written, and Caddy is reloaded only when it changes. Swapping the binary or
the systemd drop-in restarts it instead.

### Afterwards

- **Open `443/tcp` and `80/tcp` (ACME) on `caddy_bind_ip`** in the provider's
  cloud firewall -- same separate-layer caveat as the other playbooks. A
  `caddy_l4_routes` entry needs its own port opened too (`25565/tcp` for
  Minecraft).
- Caddy fetches a Let's Encrypt cert per site automatically on first request.
  Layer-4 routes are pass-through and get no cert.
- Keep private services off the public IP: anything in `caddy_sites` or
  `caddy_l4_routes` is exposed to the internet.

### Scope

Reverse-proxy only. No host hardening, no auth/WAF in front of the proxied
services -- add those per service as needed.

## pelican-wings

Installs [Pelican](https://pelican.dev) **Wings**, the daemon that owns the game
containers, on the `games` group. The Panel half is a Flux app
(`kubernetes/apps/pelican`); Wings is deliberately not in the cluster, because
game servers want a whole machine's CPU and disk rather than a scheduler's share
of one.

### 1. Register the Node first

Wings cannot bootstrap itself. In the Panel: Admin -> Nodes -> Create, FQDN
`wings-1.local.fordkuppp.me`, port `8080`, **SSL on**. The Panel then shows a
`uuid`, `token_id` and `token`; store all three in Bitwarden and pass them at
run time. Full walkthrough in
[`docs/runbooks/pelican.md`](../docs/runbooks/pelican.md).

### 2. Run it

```fish
cd ansible
ansible-playbook playbooks/pelican-wings.yaml \
  -e "tailscale_authkey=$(bws secret get $BWS_TS_GAMES_AUTHKEY_ID | jq -r .value)" \
  -e "pelican_node_uuid=$(bws secret get $BWS_PELICAN_NODE_UUID_ID | jq -r .value)" \
  -e "pelican_node_token_id=$(bws secret get $BWS_PELICAN_NODE_TOKEN_ID_ID | jq -r .value)" \
  -e "pelican_node_token=$(bws secret get $BWS_PELICAN_NODE_TOKEN_ID | jq -r .value)"
```

The role asserts the three credentials are non-empty before touching the host,
so a forgotten `-e` fails immediately rather than installing a daemon that
cannot authenticate. The closing task prints the tailnet address to put in
`caddy_l4_routes`.

### Why it is configured the way it is

- **Wings speaks plain HTTP** (`api.ssl.enabled: false`). The browser talks to
  Wings directly for the console websocket and the file manager, so it needs a
  trusted cert -- but the Envoy gateway already holds the wildcard and terminates
  TLS, so adding a node is one more `EndpointSlice`, not one more certbot.
- **`trusted_proxies` is the k3s node address** (`192.168.1.20/32`), not the pod
  CIDR. flannel masquerades pod egress on the way out of the cluster, so
  requests reach Wings from the node. (The Panel's own `TRUSTED_PROXIES` *is*
  the pod CIDR, because Envoy reaches it from inside the cluster -- the two
  values differ for a real reason.)
- **Backups mount the TrueNAS `general/backup` dataset over NFS**, which already
  has a daily snapshot task on a 14-day lifetime. Server backups are large and
  regenerable; they do not belong on the VM's own disk.
- **`tailscale_accept_routes` is off.** The box is already on the LAN; accepting
  the subnet routes it sits inside would be a routing loop waiting to happen. It
  joins the tailnet only so the Bangkok edge VPS can forward player traffic to
  it directly, rather than hairpinning through the cluster's subnet router.

### Scope

Wings only. It does not create the Node in the Panel, create servers, or open
any firewall port -- public exposure is the `caddy-gateway` role's job.
