# Ansible

Configuration layer for hosts that are not managed by Flux. Layout follows
[`docs/structure.md`](../docs/structure.md): inventory, roles and playbooks all live
here. Per-concern playbooks sit at `playbooks/`;
composite (whole-machine) playbooks that chain them live in `playbooks/composite/`.

## Provision the whole edge box

`composite/edge.yaml` runs the full stack on the `edge` group in order --
baseline hardening, the DERP relay, the Anubis bot challenge (no-op unless
`anubis_enabled`), the gateway, then the telemetry agent:

```fish
cd ansible
ansible-playbook playbooks/composite/edge.yaml \
  -e "tailscale_authkey=$(bws secret get $BWS_TS_DERP_AUTHKEY_ID | jq -r .value)"
```

It uses `import_playbook`, so each concern (`baseline.yaml`, `tailscale-derp.yaml`,
`anubis.yaml`, `caddy-gateway.yaml`, `otel-collector.yaml`) stays runnable on
its own too.

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
the second (set in the gateway's Caddyfile), so each keeps its own Let's
Encrypt cert with no
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
how a service gets a public hostname. Caddy terminates HTTPS on the second IP
and proxies to the homelab over the tailnet (the box is already a tailnet node
from `tailscale-derp`). Private, tailnet-only services like jellyfin do **not**
belong here -- reach those straight over Tailscale.

**The config is a hand-written Caddyfile**, `roles/caddy_gateway/files/Caddyfile`.
There is no template and no list of sites in the inventory: the file is the
source of truth, and the role copies it, validates it with the caddy-l4 build,
and reloads Caddy. The file's own comments explain each block; this section
covers what is not obvious from the Caddyfile alone.

### 1. Second IP + the relay rebind

This role assumes the VPS has two public IPs. derper binds the first
(`derp_bind_ip` in `inventory/group_vars/edge.yaml`); Caddy binds the second,
set in the Caddyfile as `default_bind` and on the layer4 listener. **Re-run
`tailscale-derp` first** so derper rebinds from "all interfaces" to the first
IP -- otherwise it still holds `:443` on the second IP and Caddy can't bind it.

### 2. Public HTTP apps

One site block per hostname. Upstreams must be IPs the VPS can reach over the
tailnet -- a tailnet `100.x` IP, or a homelab LAN IP (works because
`tailscale_accept_routes: true` is set for this group) -- not MagicDNS names,
because this node runs with accept-dns off.

Apps in the cluster sit behind the Envoy gateway, which terminates TLS for
`*.app.fordkuppp.me` itself. For those, proxy to `https://192.168.1.3:443`
with `tls_server_name` set to the site's hostname: Caddy re-encrypts with that
SNI and checks the certificate against it. The `*.app.fordkuppp.me` wildcard
(`kubernetes/apps/dns/records.yaml`) already resolves the name, so a new app is
the site block, the hostname in `anubis_redirect_domains`, and an HTTPRoute on
the gateway's `https-public` listener. `share.app.fordkuppp.me` in the file is
the pattern to copy.

Why re-encrypt rather than send plain HTTP over the (already encrypted)
tailnet: Envoy's OIDC filter, which gates uploads on the Send app, wants to see
HTTPS natively. A plain-HTTP listener would mean teaching Envoy to trust a
forwarded-proto header from Caddy, which is a second trust boundary for no
gain.

#### Bot challenge

Every site block that says `import anubis` runs through
[Anubis](https://anubis.techaro.lol) before it is proxied. Anubis is installed
by the [anubis](#anubis) role (`anubis_enabled`) and runs in *subrequest* mode:
Caddy's `forward_auth` asks it for a verdict on each request, a 401 bounces the
visitor to a proof-of-work page served from the same hostname under
`/.within.website/`, and a passed challenge sets a cookie good for a week. Caddy
keeps doing all the proxying, so one Anubis covers every site. Leave the
`import anubis` line out of a site to skip the challenge for it. Game servers
are raw TCP and are never challenged -- Anubis only speaks HTTP.

### 3. Minecraft servers

Minecraft speaks its own protocol on `25565/tcp`, and upstream Caddy has no
layer-4 proxy, so the role builds Caddy **from source on the controller** with
[`caddy-l4`](https://github.com/mholt/caddy-l4) compiled in -- the same
build-locally-ship-the-binary approach as `derper`, and the same **Go must be
installed locally** requirement. `caddy_version` and `caddy_l4_version` are
pinned and Renovate-tracked; the built artifact is version-stamped, so a repeat
run at the same versions skips the compile entirely.

Every game server shares the one `25565` listener and is told apart by the
hostname the player typed. HTTP can route by hostname because it carries one
in the `Host` header or the TLS SNI; Minecraft has neither, but the client
copies the typed address into its handshake packet as plain text, so caddy-l4's
`regexp` matcher reads it off the first bytes of the connection. The Caddyfile
packages that as a snippet, so **adding a server is one line** inside the
listener:

```caddyfile
import mc_server survival 100.68.244.45:25566
```

Players connect to `survival.games.fordkuppp.me`. The `*.games.fordkuppp.me`
wildcard (`kubernetes/apps/dns/records.yaml`) already resolves it and the
provider firewall port is already open, so nothing else changes. Upstreams are
the Wings host's **tailnet** address (the `pelican-wings` play prints it), so
the VPS reaches it peer-to-peer and the cluster's subnet router stays out of
the player data path. Labels are limited to 17 characters; the Caddyfile
comment on the snippet explains the byte arithmetic and why the matcher is
shaped the way it is.

A connection that matches no label -- a raw-IP connect, or an unknown name --
hits the fallback route at the bottom of the listener, which proxies to the
first server. Swap its `proxy` line for `close` to drop those instead, which
hides the server from port scanners at the cost of being unable to test the
path by IP.

There is no PROXY protocol here: Fabric and Forge cannot read it, so the server
sees every player arriving from the gateway's IP. **Ban by UUID, not by IP** --
an IP ban bans everyone.

Layer-4 listeners do not inherit `default_bind`, which is why the listener
address spells out the IP -- without that, Caddy would also claim the port on
derper's IP.

### 4. Check it before you ship it

Two checks run on the controller against the same caddy-l4 build the role
ships, so a mistake is caught before anything touches the VPS:

```fish
# Parses, and shows the matchers caddy will actually run
/tmp/caddy-v2.11.7-l4-v0.1.2 adapt --config ansible/roles/caddy_gateway/files/Caddyfile --adapter caddyfile

# Routes hand-built handshakes to the right upstream (no Minecraft client needed)
python3 ansible/roles/caddy_gateway/tests/mc_routing.py /tmp/caddy-v2.11.7-l4-v0.1.2
```

The build artifact is created by the first play run; the adapt check is also
what the role's `validate:` does on the VPS before it installs the file.

### 5. Run it

```fish
cd ansible
ansible-playbook playbooks/caddy-gateway.yaml
```

The Caddyfile is validated (`caddy validate`, using the custom binary) before it
is written, and Caddy is reloaded only when it changes. Swapping the binary or
the systemd drop-in restarts it instead.

### Afterwards

- **Open `443/tcp`, `80/tcp` (ACME) and `25565/tcp` on the second IP** in the
  provider's cloud firewall -- same separate-layer caveat as the other
  playbooks. All game servers share `25565`, so this is a one-time step.
- Caddy fetches a Let's Encrypt cert per site automatically on first request.
  Layer-4 listeners are pass-through and get no cert.
- **Game hostnames need the Cloudflare proxy off** (grey cloud). The proxy
  carries HTTP only; raw TCP through it is dropped. The `*.games` and `*.app`
  wildcards are already grey-clouded.
- Keep private services off the public IP: anything in the Caddyfile is
  exposed to the internet.


### Scope

Reverse-proxy only. No host hardening, no auth/WAF in front of the proxied
services -- add those per service as needed.

## anubis

[Anubis](https://anubis.techaro.lol) on the `edge` box, as the challenge in
front of the public HTTP sites. Installed from upstream's `.deb`, which ships a
template unit (`anubis@.service`) reading `/etc/anubis/<instance>.env`; the
role renders that file and a bot policy as `anubis@caddy`. Pinned by
`anubis_version` and Renovate-tracked.

The playbook keys off `anubis_enabled`. The Caddyfile's `import anubis` lines
assume it is on -- with Anubis absent they would `forward_auth` to a closed port
and every request would 502 -- so turn both off together. Settings worth
knowing:

- Binds loopback only (`anubis_bind`, `anubis_metrics_bind`). The VPS has two
  public IPs and upstream's default is every interface.
- `TARGET=" "` -- a single space -- is Anubis's documented value for "there is
  no upstream, I only answer the check endpoint".
- The policy is upstream's default with `DENY` answering 403 instead of 200,
  because in subrequest mode a 200 from the check endpoint means "allow".
  The tier a plain browser lands in (weight 10-19) is difficulty 4.
- **Visitors outside Thailand weigh 10 more.** Anubis can only match a *list*
  of countries, so the policy adds 10 to every request and takes it back for
  `TH`; an address the database cannot place counts as foreign. A browser
  abroad lands in the 20-29 tier, which is also difficulty 4, so for browsers
  this changes nothing yet. The visible effect is on non-browser clients
  (curl, scripts, chat-app link previews): from Thailand they pass
  unchallenged, from anywhere else they get a challenge they cannot solve.
- The country database is DB-IP's free *IP to Country Lite* (CC BY 4.0,
  <https://db-ip.com>), no account needed, at
  `/var/lib/anubis-geoip/dbip-country-lite.mmdb`. The `anubis-geoip-update`
  timer refreshes it monthly by renaming the new file over the old one --
  Anubis memory-maps it, so it must never be overwritten in place -- and
  restarts Anubis, which costs visitors one fresh challenge (see the next
  point). Upstream's ASN rules stay off: they need a second database.
- `REDIRECT_DOMAINS` is `anubis_redirect_domains` in `group_vars/edge.yaml`:
  every hostname whose site block imports the anubis snippet. Unset, Anubis
  warns about an open redirect.
- The signing key is generated at start, so a restart invalidates every
  visitor's pass cookie and they solve one more challenge. Harmless at this
  scale; set `ED25519_PRIVATE_KEY_HEX` from a secret if that ever matters.

```fish
cd ansible
ansible-playbook playbooks/anubis.yaml
```

Verify with `curl http://127.0.0.1:9090/metrics` on the box, and from outside
by opening a site in a browser: the first visit shows the challenge page for a
moment, then the app.

## otel-collector

The OpenTelemetry Collector (contrib build) on the `edge` box, shipping its
metrics and logs to the cluster's collector at `otel-http.local.fordkuppp.me`
over the tailnet. That collector already writes metrics to Prometheus and logs
to Loki, so the VPS shows up next to the cluster with no cluster-side change.

What it collects is the hand-written `roles/otel_collector/files/config.yaml`;
the role installs upstream's pinned `.deb` (`otelcol_version`,
Renovate-tracked), copies the file, and validates it with the installed binary
before restarting. A bad edit never replaces a working config.

| Source | Receiver | Lands as |
|---|---|---|
| Caddy, per site (`metrics { per_host }` in the Caddyfile) | `prometheus`, `localhost:2019` | `job="caddy"` |
| Anubis | `prometheus`, `127.0.0.1:9090` | `job="anubis"` |
| CPU, memory, load, disk, filesystem, network | `hostmetrics` | `job="edge-host"` |
| caddy, anubis@caddy, derper, tailscaled, fail2ban, ssh | `journald` | Loki, `service_name` = the unit |

All metrics carry `instance="derp-bkk-01"`.

Things that are not obvious from the config:

- **No Fluent Bit.** The `journald` receiver reads the journal by running
  `journalctl`, which is why this is a native install rather than a container,
  and why the role adds the service user to `systemd-journal`.
- **The config goes in before the package.** Upstream's `.deb` starts the
  service at install time with a sample config that listens for OTLP, pprof,
  zpages, Jaeger and Zipkin on `0.0.0.0` -- the public IPs here. The role
  creates the user and writes the real config first, and dpkg keeps it, so
  that sample never runs.
- **The journal directory is set explicitly.** The receiver defaults to the
  volatile `/run/log/journal`; Ubuntu's persistent journal is
  `/var/log/journal`.
- **The journal cursor is persisted** under `/var/lib/otelcol-contrib`, so a
  restart neither drops nor re-sends lines.
- **A 150 MiB memory limit.** The VPS has under 1 GB and the collector should
  shed data before it competes with Caddy or derper.
- **No traces.** Caddy can emit OTLP traces, but the cluster collector has no
  traces pipeline or backend yet.

```fish
cd ansible
ansible-playbook playbooks/otel-collector.yaml
```

Verify with `systemctl status otelcol-contrib` and
`journalctl -u otelcol-contrib -n 20` on the box (look for export errors), then
in Grafana: `up{instance="derp-bkk-01"}` in Prometheus, and
`{service_name="caddy"}` in Loki.

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
cannot authenticate. The closing task prints the tailnet address and the
`import mc_server` line to add to the gateway's Caddyfile.

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
- Only then expose it: add an `import mc_server <label> <tailnet-ip>:25565`
  line to `roles/caddy_gateway/files/Caddyfile` and follow
  [caddy-gateway](#caddy-gateway). The wildcard record already resolves it and
  25565 is already open, so no DNS or firewall change is needed per server.

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
