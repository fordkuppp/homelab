# Pelican game panel — design

Date: 2026-11-02
Status: approved for planning

## Goal

Run [Pelican](https://pelican.dev) as the homelab's game-server control plane:
the **Panel** (web UI, Laravel) in the k3s cluster alongside every other app,
and **Wings** (the daemon that owns the game containers) on its own Proxmox VM.
First workload is a Fabric/Forge Minecraft modpack, reachable from the public
internet.

Splitting them is deliberate. Wings needs its own Docker daemon and binds
arbitrary game ports; running that inside k3s means nested container runtimes
and a port-allocation story that fights the cluster. A VM keeps the blast
radius of a runaway game server off the cluster, and lets game servers survive
a cluster outage.

## Topology

```
Internet (players)
   │  :25565/tcp → 117.18.125.45       (caddy_bind_ip, the VPS's 2nd public IP)
   ▼
edge VPS  derp-bkk-01  (Bangkok, group `edge`)
   derper  :443  on 117.18.125.44       (unchanged)
   caddy   :443  HTTP sites             (unchanged, caddy_sites)
           :25565 layer4 proxy ─────┐    ← new; needs a caddy-l4 build
                                    │
   └────────── tailnet, peer-to-peer ───────────┐
                                                │
home LAN 192.168.1.0/24                         │
   ├─ k3s-1 (.20)                               │
   │    pelican-panel pod, SQLite on local-path │
   │    Envoy LAN VIP .3                        │
   │      panel.local.fordkuppp.me   → panel Service :80
   │      wings-1.local.fordkuppp.me → EndpointSlice .30:8080
   │                                            │
   └─ wings-1 (.30) ◄───────────────────────────┘
        tailscaled                 (tag:games, accept-routes off)
        :8080  Wings API           plain HTTP; the gateway terminates TLS
        :2022  SFTP                direct, LAN/tailnet only
        :25565+ game allocations
        /var/lib/pelican/backups → NFS 192.168.1.11:/mnt/general/backup
```

**One Wings, many servers.** A Wings daemon is one *Node* in the Panel, and a
node hosts many servers — each on its own port allocation (`25565`, `25566`, …).
Extra Minecraft servers cost one allocation plus one `layer4` listener on the
VPS. A second Wings VM is only needed when 8 GB runs out; it would be one new
`wings-2.yaml` beside the first, covered by the same wildcard cert.

## Decisions

### D1 — Panel database: SQLite on a `local-path` PVC

Pelican supports MySQL 8.4+, MariaDB 10.11+, **PostgreSQL 17+**, and SQLite.
The shared CNPG cluster runs `cloudnative-vectorchord:16.12` — below Pelican's
floor — so the existing `ExternalSecret` + `DatabaseRole` + `Database` pattern
used by pocket-id and immich is not available without a major-version upgrade
of a cluster that immich, pocket-id and actual all depend on. That is far too
much blast radius for one new app.

SQLite is Pelican's own default and is sized correctly for a single-admin panel
with a handful of servers. It avoids standing up a second database engine
(MariaDB) purely for this.

`local-path`, not `nfs-csi`: SQLite locking over NFS is a known corruption
path. The cluster is single-node, so `local-path`'s node affinity costs
nothing, and it is already what the *arr config volumes use.

### D2 — Wings TLS terminates at the Envoy gateway

The browser talks to Wings directly for the console websocket and the file
manager, so Wings needs a publicly-trusted certificate. Two options were
considered:

| | Gateway terminates | Wings holds its own cert |
|---|---|---|
| Cert lifecycle | existing cert-manager wildcard | new certbot + Cloudflare creds per VM |
| Cost of node #2 | ~20 lines of YAML | repeat the whole cert setup |
| Survives cluster outage | no | yes (but the Panel doesn't either) |

Gateway wins. The "survives a cluster outage" advantage is hollow: the Panel
itself lives in k3s, so a cluster outage takes the web UI down regardless.
Game servers keep running in both designs — Wings holds the containers up
independently of the Panel.

This reuses the selector-less `Service` + `EndpointSlice` + `HTTPRoute` pattern
already proven in `kubernetes/apps/external/proxmox.yaml`.

### D3 — Public Minecraft ingress via `caddy-l4` on the edge VPS

Home is behind AIS CGNAT, so nothing at home is reachable from the internet
directly. Public players must enter at the Bangkok VPS, which has two public
IPs; derper owns `:443` on the first, Caddy owns the second.

Caddy as currently installed **cannot** do this. The `caddy_gateway` role
installs the stock apt build and the Caddyfile template only emits
`reverse_proxy` HTTP sites. Minecraft is raw TCP, which needs the
[`caddy-l4`](https://github.com/mholt/caddy-l4) module and therefore a custom
`xcaddy` build.

Alternatives rejected: a Minecraft-aware proxy (Infrared) would give real
player IPs via PROXY protocol and hostname routing on one port, but is
Minecraft-only and adds a service; nftables DNAT is simpler but needs a port
per server and loses real IPs anyway.

**Consequence: all players appear to come from one source IP.** Fabric/Forge
cannot reliably read PROXY protocol, so `proxy_protocol` stays off. Ban by
player UUID, not IP — which is the normal mechanism in Minecraft.

### D4 — `tailscaled` on the Wings VM, not a new Connector route

The VPS reaches home over the tailnet. The obvious move is adding
`192.168.1.30/32` to the k8s `Connector`, but that routes every Minecraft
packet through the Connector pod in k3s — putting the cluster in the player
data path, where a Flux reconcile would drop players.

Running `tailscaled` on the Wings VM instead makes the VPS↔VM hop
peer-to-peer, leaves `connector.yaml` untouched, and removes the cluster from
the game path entirely.

Expect a direct connection: the VPS has a public IP, which is the easy
NAT-traversal case. Worst case it relays via `derper` on that same VPS — the
same round trip.

`accept-routes` is **off** on this node. It already sits on the LAN; accepting
`192.168.1.x` routes from the Connector would be a routing loop.

### D5 — Extract a `tailscale_node` role

`tailscale_derp/tasks/main.yaml` lines 2–50 are generic "install tailscaled and
join the tailnet" logic, and the Wings VM needs exactly that. Rather than
copying it, extract those tasks and the `--- Tailscale node ---` half of the
defaults into a new `tailscale_node` role, and make `tailscale_derp` depend on
it.

This touches a working edge-box role, so it is its own implementation step with
its own verification against `derp-bkk-01` before the Wings work builds on it.

### D6 — Game-server backups to the existing TrueNAS `backup` dataset

Wings has a built-in backup driver. The Panel's SQLite covers panel metadata,
but world data lives on the VM and would otherwise be unprotected — and it is
the only genuinely irreplaceable data in the system.

`general/backup` already exists as a dataset with an NFS share
(`/mnt/general/backup`) and a daily snapshot task on a 14-day lifetime. Mount
it on the Wings VM at Wings' `system.backup_directory`. Zero new
infrastructure, zero cost, already snapshotted. The cloud-init image already
installs `nfs-common`.

Note that the *driver* (`wings` vs `s3`) is a Panel setting, not a key in
`config.yml` — Wings has no `backups.driver`. Leaving the Panel on its default
`wings` driver makes Wings write archives to `system.backup_directory`, which
is the mount.

Rejected: rustfs (`docker-1:9000`) — it lives on the VM being decommissioned
(see P1). Cloudflare R2 — real storage and egress cost for multi-GB worlds,
when a snapshotted local dataset is sufficient.

## Prerequisites

### P1 — `192.168.1.30` must be freed first

`docker-1` currently holds `.30`
(`terragrunt/proxmox/vm/docker-1/terragrunt.hcl`). Komodo is no longer in use,
so that VM is to be decommissioned and `wings-1` takes the address.

Before destroying it, confirm nothing still depends on what it hosts:

- **Komodo** — `docker/compose/komodo/`, `docker/komodo/`,
  `terragrunt/proxmox/vm/script/install-komodo.sh`. Retired; remove with the VM.
- **rustfs** (`docker/compose/rustfs/`, S3 on `:9000`) — **verify before
  destroying.** k8up is *not* affected: its schedules target Cloudflare R2
  (`kubernetes/apps/k8up/secrets.yaml` → `cloudflare_r2_endpoint`). If nothing
  else consumes rustfs, it goes with the VM.

Decommissioning `docker-1` is destructive and out of scope for this spec — it
is a separate, explicitly-approved step that must land before the Wings VM is
applied. If it turns out `docker-1` must stay, `wings-1` takes `.31` instead and
only `docs/ip-plan.md` changes.

### P2 — Tailnet policy

A `tag:games` entry in `tagOwners`, and a tagged pre-auth key (or OAuth client
secret) stored in Bitwarden Secrets Manager. Passed at run time, never
committed — same handling as `tailscale_authkey` for the edge box.

### P3 — DNS

- `panel.local.fordkuppp.me` and `wings-1.local.fordkuppp.me` — written by
  `external-dns-local` from the HTTPRoutes; no manual record needed.
- `mc.fordkuppp.me` — manual `A` record → `117.18.125.45` (`caddy_bind_ip`),
  proxy **off** (Cloudflare's proxy does not carry raw TCP).

## Components

### 1. Proxmox VM — `terragrunt/proxmox/vm/wings-1/terragrunt.hcl`

`proxmox-vm` module, following `k3s-1`'s shape:

| | |
|---|---|
| `vm_id` | `1201` |
| `cpu_cores` | 4 |
| `memory` | 8192 |
| `disk_size_gb` | 100 |
| `disk_ssd` / `disk_discard` | `true` / `"on"` |
| `ip_address` | `192.168.1.30/24` |
| `tags` | `["games", "wings"]` |

Cloud-init already installs `docker-ce` and `nfs-common`, which is everything
Wings needs from the image. Everything else is Ansible's job.

**Module change:** `variable "user_data"` currently has no default, so a VM
whose configuration is entirely Ansible's responsibility is forced to pass a
dummy script. Give it `default = ""` and make the cloud-init `runcmd` skip the
`user-data.sh` invocation when it is empty. This is the structural fix;
committing a no-op `.sh` is not.

### 2. Inventory

New group `games` in `inventory/hosts.yaml`:

```yaml
games:
  hosts:
    wings-1:
      ansible_host: 192.168.1.30
      ansible_user: ubuntu
```

New `inventory/group_vars/games.yaml` holding `tailscale_tags: "tag:games"`,
`tailscale_accept_routes: false`, the pinned `pelican_wings_version`, and the
Panel URL.

### 3. `ansible/roles/tailscale_node` (new, extracted)

Tasks moved verbatim from `tailscale_derp`: auth-key assert, install via the
official script, enable `tailscaled`, check `tailscale status --json`, join on
first run, and reconcile mutable prefs with `tailscale set` on every run.
Defaults move with them (`tailscale_authkey`, `tailscale_hostname`,
`tailscale_tags`, `tailscale_accept_routes`, `tailscale_up_args`).

`tailscale_derp` gains `dependencies: [tailscale_node]` in `meta/main.yaml` and
keeps only the derper half. Its behaviour must not change.

### 4. `ansible/roles/pelican_wings` (new)

- Install the pinned Wings binary to `/usr/local/bin/wings`
  (`pelican_wings_version`, arch-aware URL).
- Create `/etc/pelican` and `/var/lib/pelican`.
- Mount `192.168.1.11:/mnt/general/backup` at `/var/lib/pelican/backups`
  (Wings' default `system.backup_directory`) via `/etc/fstab`
  (`nfsvers=4`, `soft`), matching the rustfs compose mount options.
- Template `/etc/pelican/config.yml` from the node credentials
  (`uuid`, `token_id`, `token`) passed at run time from Bitwarden, plus static
  settings: `api.host: 0.0.0.0`, `api.port: 8080`, `api.ssl.enabled: false`,
  `api.trusted_proxies: ["192.168.1.20/32"]` — Wings sits behind Envoy, and
  flannel masquerades pod egress leaving the cluster, so requests arrive from
  the k3s *node* address, not the pod CIDR,
  `remote: https://panel.local.fordkuppp.me`, `allowed_origins`, and
  `system.data: /var/lib/pelican/volumes`.
- Install and enable the `wings.service` systemd unit from the Pelican docs
  (`After=docker.service`, `Requires=docker.service`, `PartOf=docker.service`).
- A closing `debug` task printing the node's tailnet IPv4 and the
  `caddy_l4_routes` line to paste into `group_vars/edge.yaml` — mirroring how
  `tailscale_derp` ends by printing the DNS record and `derpMap`.

No host firewall. Nothing in this repo runs ufw/nftables on LAN hosts, and
Docker bypasses ufw anyway; the VM is LAN-only except for what Caddy forwards.

### 5. `ansible/roles/caddy_gateway` (extended)

The largest change to existing code.

- **New var `caddy_l4_routes`** — a list of `{listen_port, upstream}`.
- **Custom Caddy build.** `xcaddy build v{{ caddy_version }} --with
  github.com/mholt/caddy-l4@v{{ caddy_l4_version }}` runs **on the controller**
  and the static binary is shipped to the VPS — the same delegate-to-localhost
  pattern `tailscale_derp` already uses for `derper`, and Go is already a
  controller prerequisite. The binary lands at `/usr/local/bin/caddy`; a
  systemd drop-in at
  `/etc/systemd/system/caddy.service.d/10-custom-binary.conf` overrides
  `ExecStart`/`ExecReload` (reset with an empty assignment first). The apt
  package stays installed for the unit, the `caddy` user and `/etc/caddy`, so
  an apt upgrade cannot silently restore a plugin-less binary.
- **Relax the assert** from `caddy_sites | length > 0` to sites **or** L4
  routes — the Minecraft listener must not require an HTTP site.
- **Pin the validator** to `/usr/local/bin/caddy validate …`; the default
  `caddy` on `PATH` resolves to the apt build, which rejects `layer4`.

Caddyfile addition, inside the global options block:

```caddyfile
layer4 {
	{{ caddy_bind_ip }}:25565 {
		route {
			proxy <wings-1 tailnet IPv4>:25565
		}
	}
}
```

`default_bind` does **not** apply to layer4 listeners, so the bind IP is
explicit — otherwise it listens on `0.0.0.0` and spills onto derper's IP.

### 6. `ansible/playbooks/`

- `pelican-wings.yaml` — `hosts: games`, roles `tailscale_node`,
  `pelican_wings`.
- `composite/wings.yaml` — `import_playbook` of `baseline.yaml` (scoped to
  `games`) then `pelican-wings.yaml`, mirroring `composite/edge.yaml`.

`baseline` currently hardcodes `hosts: edge`. Change it to
`hosts: "{{ baseline_hosts | default('edge') }}"` so `composite/edge.yaml`
keeps working untouched while `composite/wings.yaml` can pass `games`.

### 7. `kubernetes/apps/pelican/`

| File | Contents |
|---|---|
| `namespace.yaml` | `pelican`, label `k8up-backup: enabled` |
| `pv.yaml` / `pvc.yaml` | 5 Gi, `local-path` |
| `deployment.yaml` | Deployment + Service |
| `backup-cronjob.yaml` | nightly consistent SQLite snapshot |
| `httproute.yaml` | `panel.local.fordkuppp.me` → panel `:80` |
| `wings-1.yaml` | Service + EndpointSlice + HTTPRoute + BackendTrafficPolicy |
| `kustomization.yaml` | the above, in order |

**Deployment** — `ghcr.io/pelican/panel:v1.0.0-rc.2`, one replica,
`strategy: Recreate` (RWO volume), `enableServiceLinks: false` to match house
style. Env: `XDG_DATA_HOME=/pelican-data`, `APP_URL=https://panel.local.fordkuppp.me`,
`APP_ENV=production`, `APP_DEBUG=false`, `APP_TIMEZONE=Asia/Bangkok`,
`TZ=Asia/Bangkok`, `BEHIND_PROXY=true`, `TRUSTED_PROXIES` = the pod CIDR,
`ADMIN_EMAIL`. Volumes: the PVC at `/pelican-data`, an `emptyDir` at
`/var/www/html/storage/logs`.

Probes are `httpGet /` on port 80. Before the install wizard runs, `/` returns
a 302 to `/installer`; Kubernetes counts 200–399 as success, so this works in
both states. (A `/up`-style health endpoint was not assumed.)

**`wings-1.yaml`** — lifted from `external/proxmox.yaml`: a selector-less
`Service` on `:8080`, an `EndpointSlice` pointing at `192.168.1.30:8080`, an
`HTTPRoute` for `wings-1.local.fordkuppp.me` on `tailscale-gateway`, and a
`BackendTrafficPolicy` with `timeout.http.requestTimeout: "0s"` — the console
is a long-lived websocket, exactly like the PVE console that policy already
exists for.

**`backup-cronjob.yaml`** — restic snapshots a live SQLite file, which can tear
if a write lands mid-copy. A nightly CronJob running
`sqlite3 database.sqlite ".backup /pelican-data/backups/panel.sqlite"` before
the k8up window gives a guaranteed-consistent copy for ~20 lines. It mounts the
same RWO PVC, which is fine: both pods land on the single node.

### 8. `kubernetes/flux/pelican.yaml`

Standard Kustomization, `dependsOn: [systems]`. No Postgres dependency.

### 9. `kubernetes/apps/k8up-schedules/pelican.yaml`

Copy of `pocket-id.yaml` with bucket `homelab-backups/pelican`, backup at
`05 3 * * *` (after the CronJob, clear of the existing 2:15/3:45 slots),
retention `keepDaily 14 / keepWeekly 8 / keepMonthly 6`.

### 10. `renovate.json`

Three new custom managers following the `derper_version` one:

| Pin | Source |
|---|---|
| `pelican_wings_version` | `pelican/wings`, github-releases |
| `caddy_version` | `caddyserver/caddy`, github-releases |
| `caddy_l4_version` | `mholt/caddy-l4`, github-releases |

Plus a package rule for `pelican/**` and `ghcr.io/pelican/**` with
`ignoreUnstable: false` and `automerge: false`. Pelican is on `v1.0.0-rc.2`;
Renovate skips prereleases by default and would otherwise never offer a bump.

The Panel image in `deployment.yaml` is picked up by the existing `kubernetes`
manager automatically.

### 11. Docs

**`docs/ip-plan.md`** — rename the `192.168.1.30–39` range from
"Komodo docker" to "Game servers", and record `192.168.1.30 — wings-1 (Pelican
Wings)".

**`docs/runbooks/pelican.md`** (new) — the one-time manual steps that have no
API: running the Panel install wizard, creating the Node in the UI, moving the
generated `uuid`/`token_id`/`token` into Bitwarden, and the first server
creation.

## Manual steps

Two things cannot be automated and are documented rather than coded:

1. **Panel install wizard.** First boot serves `/installer`; it creates the
   admin user and writes the initial config into `/pelican-data`.
2. **Node registration.** The Panel generates the node UUID and token; there is
   no API to bootstrap it cold. Create the Node in the UI, then store the three
   values in Bitwarden so Ansible can template `config.yml` reproducibly
   thereafter.

## Implementation order

1. Decommission `docker-1`, freeing `.30` (separate approval — see P1).
2. `proxmox-vm` module `user_data` default; `wings-1` terragrunt; apply.
3. Extract `tailscale_node`; **re-run against `derp-bkk-01` and verify no
   change** before going further.
4. `pelican_wings` role + playbooks; run against `wings-1`.
5. Panel in k3s + Flux Kustomization; run the install wizard.
6. Register the node in the UI; store credentials; re-run the Wings play.
7. Create the first Minecraft server; verify over LAN.
8. Extend `caddy_gateway` for layer4; DNS record; open `25565/tcp` in the
   provider security group; verify from off-net.
9. k8up schedule, SQLite CronJob, Renovate managers, docs.

Steps 2–4 and step 5 are independent and can proceed in parallel.

## Verification

| Check | Command / expectation |
|---|---|
| VM reachable | `ansible games -m ping` |
| Tailnet peer-to-peer | `tailscale ping wings-1` from the VPS → `direct`, not `via DERP` |
| derper unaffected | `tailscale netcheck` still lists the `bkk` region |
| Wings up | `systemctl status wings`; `curl localhost:8080` on the VM |
| Wings via gateway | `curl -I https://wings-1.local.fordkuppp.me` → Wings responds, valid cert |
| Panel up | `https://panel.local.fordkuppp.me` loads |
| Panel ↔ Wings | node shows green in the Panel UI (see R2) |
| Console websocket | open a server console; it streams and does not time out |
| Caddy build has l4 | `/usr/local/bin/caddy list-modules \| grep layer4` |
| Caddy config valid | `/usr/local/bin/caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile` |
| Public reach | connect to `mc.fordkuppp.me` from off-net (mobile data) |
| Backups | a Wings backup appears under `/mnt/general/backup` on TrueNAS |
| Panel backup | a k8up snapshot lands in `homelab-backups/pelican` |

## Risks

**R1 — Pelican is `v1.0.0-rc.2`, pre-1.0.** Breaking changes between release
candidates are realistic. Nothing Pelican automerges; read the changelog on
every bump.

**R2 — Panel→Wings hairpins through the gateway.** The Panel pod resolves
`wings-1.local.fordkuppp.me` to `192.168.1.3` (the MetalLB VIP with
`externalTrafficPolicy: Local`), goes out to Envoy, and back to the VM. On a
single-node cluster the Envoy pod is on that node, so this should work — but it
is the single most likely thing to break, and should be verified first. Fallback
is D2's rejected option: give Wings its own DNS-01 certificate and drop the
gateway route.

**R3 — Players share one source IP** (D3). IP bans and anti-VPN plugins will
not work. Ban by UUID.

**R4 — Custom Caddy binary.** Updates are now the repo's responsibility rather
than apt's. Mitigated by the Renovate pins on both `caddy_version` and
`caddy_l4_version`, and by the systemd drop-in that stops an apt upgrade from
silently reverting the binary. The role must be re-run to apply a bump.

**R5 — Public `:25565` attracts scanners.** Keep `online-mode: true` and the
whitelist on. A non-standard public port plus an SRV record reduces drive-by
noise if it becomes a problem.

**R6 — All Minecraft traffic transits Bangkok** and counts against the VPS's
bandwidth allowance. Latency impact is small (VPS and home are both in
Thailand), but the quota is finite.

**R7 — The Wings tailnet IP is pinned by hand** in `group_vars/edge.yaml`.
Tailscale addresses are stable for a node's lifetime, so this only matters if
the VM is rebuilt — at which point the role's closing `debug` prints the new
value.

## Out of scope

- Decommissioning `docker-1` (prerequisite P1, separate approval).
- Non-Minecraft games. The design is game-agnostic — `caddy-l4` forwards any
  TCP — but only Minecraft is being configured.
- A second Wings node.
- Public exposure of the Panel or the Wings API; both stay LAN/tailnet-only via
  the existing gateway.
- Migrating off the VPS hop. If AIS will sell a routable IP, forwarding
  `25565` at the home router deletes the entire `caddy-l4` component. Worth
  asking before step 8; it does not block anything earlier.
