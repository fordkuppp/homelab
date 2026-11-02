# Ansible

Configuration layer for hosts that are not managed by Flux. Layout follows
[`docs/structure.md`](../docs/structure.md): inventory, roles and playbooks all live
here. Per-concern playbooks sit at `playbooks/`;
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
See [pelican-wings](#pelican-wings) for how to get them, and `docs/ip-plan.md`
for why the VM takes `192.168.1.30`.

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

If the tailnet has **device approval** enabled, tick **Pre-approved** on the
key. Without it the node authenticates but parks in `NeedsMachineAuth` until an
admin approves it at <https://login.tailscale.com/admin/machines>, and the play
fails after `tailscale_up_timeout` (60s) rather than joining.

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

## docker

Docker Engine from Docker's own apt repo, not Ubuntu's `docker.io` -- the distro
package lags by releases and Wings talks to the Engine API directly. Container
logs are capped (`10m` x 3) in `/etc/docker/daemon.json`, because game servers
are chatty and long-lived and the first symptom of the default unbounded
`json-file` driver is a full disk.

Not run on its own; `pelican_wings` pulls it in as a meta dependency.

## pelican-wings

Installs [Pelican](https://pelican.dev) **Wings**, the daemon that owns the game
containers, on the `games` group. The Panel half is a Flux app
(`kubernetes/apps/pelican`); Wings is deliberately not in the cluster, because
game servers want a whole machine's CPU and disk rather than a scheduler's share
of one.

The Minecraft server itself runs **here**, as a Docker container Wings creates
and supervises — the Panel only drives it. World data lives in
`/var/lib/pelican/volumes/<server-uuid>`. The role pulls in `docker` as a meta
dependency; Wings calls `ConfigureDocker()` during boot and a missing daemon is
a fatal exit, not a degraded mode.

### 1. Bring the Panel up and register the Node

Wings cannot bootstrap itself, and the Panel has no API to create a Node cold,
so this order is not negotiable:

1. **Panel** -- merge to `main`, then `flux -n flux-system reconcile
   kustomization pelican --with-source`. Confirm
   `https://panel.local.fordkuppp.me` loads.
2. **Install wizard** -- the first visit serves `/installer`, which creates the
   admin user and writes configuration into `/pelican-data`. **Keep the SQLite
   default**: the PVC is `local-path` precisely because SQLite locking over NFS
   corrupts.
3. **Create the Node** -- Admin -> Nodes -> Create:

   | Field | Value |
   |---|---|
   | FQDN | `wings-1.local.fordkuppp.me` |
   | Daemon port | `8080` |
   | SSL | **on** -- the Envoy gateway presents the wildcard cert |
   | Daemon SFTP port | `2022` |

   SSL is on even though Wings serves plain HTTP; see
   [Why it is configured the way it is](#why-it-is-configured-the-way-it-is).

4. The Panel then shows a `uuid`, a `token_id` and a `token`. Store all three in
   Bitwarden and export their ids as `BWS_PELICAN_NODE_UUID_ID`,
   `BWS_PELICAN_NODE_TOKEN_ID_ID` and `BWS_PELICAN_NODE_TOKEN_ID`.

The tailnet auth key is separate: create a **tagged** pre-auth key for
`tag:games` (declare the tag in `tagOwners` first) and export its id as
`BWS_TS_GAMES_AUTHKEY_ID`. Tick **Pre-approved** if device approval is on --
see [Get a tagged auth key](#1-get-a-tagged-auth-key).

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

### Afterwards

- The node should turn **green** in the Panel UI. If it does not, the usual
  causes are the gateway route (`curl -I https://wings-1.local.fordkuppp.me`)
  and the node token -- in that order.
- Create the server (a Fabric or Forge egg, allocated `192.168.1.30:25565`) and
  **connect from the LAN first**. That isolates the server itself from the
  public path before you add a second variable.
- Only then expose it: feed the printed tailnet address into `caddy_l4_routes`
  and follow [caddy-gateway](#caddy-gateway). Point `mc.fordkuppp.me` at the
  gateway IP with the Cloudflare proxy **off** -- the proxy handles HTTP only,
  and this is raw TCP.

### Scope

Wings only. It does not create the Node in the Panel, create servers, or open
any firewall port -- public exposure is the `caddy-gateway` role's job.

### Adding a second Wings node

One Wings daemon is one Panel "Node" and hosts many servers, so a second node is
only needed for a second machine. Three changes, no new patterns: a
`terragrunt/proxmox/vm/wings-2/` directory plus a `wings-2` entry under `games`
in `inventory/hosts.yaml`; a copy of `kubernetes/apps/pelican/wings-1.yaml` with
the name, hostname and `EndpointSlice` address changed (the wildcard cert
already covers it); then register the Node and re-run `composite/wings.yaml`.
