# Pelican: bringing up the Panel and a Wings node

Everything in this repo is declarative except the parts Pelican gives no API
for: the Panel's install wizard and Node registration. Those produce the
credentials Ansible needs, so the order below is not negotiable — the Panel has
to exist and have a Node before the Wings play can run.

Architecture in one line: the **Panel** is a Flux app in k3s
(`kubernetes/apps/pelican`), **Wings** and the game containers live on
`wings-1` at `192.168.1.30`, and public Minecraft traffic enters at the Bangkok
edge VPS where `caddy-l4` forwards raw TCP over the tailnet.

## 1. Prerequisite — free up `.30`

`docker-1` held `192.168.1.30` and is retired along with Komodo. Decommission it
before provisioning, or the new VM will collide. See
[`docs/ip-plan.md`](../ip-plan.md).

## 2. Tailnet — tag and key

In the Tailscale admin console:

- Add `tag:games` to `tagOwners` in the tailnet policy.
- Create a **tagged** pre-auth key for it.
- Store the key in Bitwarden Secrets Manager; export its id as
  `BWS_TS_GAMES_AUTHKEY_ID`.

## 3. VM

```fish
terragrunt apply --working-dir terragrunt/proxmox/vm/wings-1
```

4 vCPU / 8 GB / 100 GB, static `192.168.1.30/24`. No `user_data` — Ansible does
all configuration.

## 4. Panel

Merge to `main` and wait for Flux:

```fish
flux -n flux-system reconcile kustomization pelican --with-source
```

Then confirm `https://panel.local.fordkuppp.me` loads.

## 5. Install wizard

The first visit serves `/installer`. It creates the admin user and writes
configuration into `/pelican-data`. **Keep the SQLite default** — the PVC is
`local-path` precisely because SQLite locking over NFS corrupts, and the Panel's
write volume is tiny.

## 6. Create the Node

Admin → Nodes → Create:

| Field | Value |
|---|---|
| FQDN | `wings-1.local.fordkuppp.me` |
| Daemon port | `8080` |
| SSL | **on** — the Envoy gateway presents the wildcard cert |
| Daemon SFTP port | `2022` |

SSL is on even though Wings itself serves plain HTTP: the browser talks to Wings
directly for the console websocket and the file manager, and the gateway is what
terminates TLS.

The Panel then shows a `uuid`, a `token_id` and a `token`. Put all three in
Bitwarden and export their ids as `BWS_PELICAN_NODE_UUID_ID`,
`BWS_PELICAN_NODE_TOKEN_ID_ID` and `BWS_PELICAN_NODE_TOKEN_ID`.

## 7. Prove the snapshot job

A database now exists, so don't wait until 02:55 to find out the backup is
broken:

```fish
kubectl -n pelican create job --from=cronjob/pelican-sqlite-snapshot snapshot-test
kubectl -n pelican logs job/snapshot-test   # expect: snapshot written to ...
kubectl -n pelican delete job snapshot-test
```

## 8. Run the composite play

```fish
cd ansible
ansible-playbook playbooks/composite/wings.yaml \
  -e "tailscale_authkey=$(bws secret get $BWS_TS_GAMES_AUTHKEY_ID | jq -r .value)" \
  -e "pelican_node_uuid=$(bws secret get $BWS_PELICAN_NODE_UUID_ID | jq -r .value)" \
  -e "pelican_node_token_id=$(bws secret get $BWS_PELICAN_NODE_TOKEN_ID_ID | jq -r .value)" \
  -e "pelican_node_token=$(bws secret get $BWS_PELICAN_NODE_TOKEN_ID | jq -r .value)"
```

The final task prints the host's tailnet IPv4. Keep it — step 11 needs it.

## 9. Verify the node

It should turn green in the Panel UI. If it does not, the usual causes are the
gateway route (`curl -I https://wings-1.local.fordkuppp.me`) and the node token.

## 10. Create the Minecraft server

Pick a Fabric or Forge egg, allocate `192.168.1.30:25565`, start it, and connect
from the LAN first. Do not move on until the LAN works — it isolates the server
itself from the public path.

## 11. Public exposure

1. Set `caddy_l4_routes` in `inventory/group_vars/edge.yaml` to the tailnet IP
   from step 8:

   ```yaml
   caddy_l4_routes:
     - listen_port: 25565
       upstream: "100.x.y.z:25565"
   ```

2. `cd ansible; ansible-playbook playbooks/caddy-gateway.yaml` — this is the run
   that rebuilds Caddy from source with `caddy-l4`, so **Go must be installed on
   the controller**.
3. Create the `mc.fordkuppp.me` A record to `117.18.125.45` with the Cloudflare
   proxy **off** — the proxy only handles HTTP, and this is raw TCP.
4. Open `25565/tcp` on `117.18.125.45` in the ReadyIDC security group. A route
   that looks correct but is unreachable is almost always a closed
   security-group port.

> **All players share one source IP.** Fabric and Forge cannot read the PROXY
> protocol, so every connection arrives from the gateway. **Ban by UUID, not by
> IP** — an IP ban here bans everyone.

## 12. Verify end to end

| Check | Command / expectation |
|---|---|
| VM reachable | `ansible games -m ping` |
| Tailnet peer-to-peer | `tailscale ping wings-1` from the VPS → `direct`, not `via DERP` |
| derper unaffected | `tailscale netcheck` still lists the `bkk` region |
| Wings up | `systemctl status wings`; `curl localhost:8080` on the VM |
| Wings via gateway | `curl -I https://wings-1.local.fordkuppp.me` → Wings responds, valid cert |
| Panel up | `https://panel.local.fordkuppp.me` loads |
| Panel ↔ Wings | node shows green in the Panel UI |
| Console websocket | open a server console; it streams and does not time out |
| Caddy build has l4 | `/usr/local/bin/caddy list-modules \| grep layer4` |
| Caddy config valid | `/usr/local/bin/caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile` |
| Public reach | connect to `mc.fordkuppp.me` from off-net (mobile data) |
| Backups | a Wings backup appears under `/mnt/general/backup` on TrueNAS |
| Panel backup | a k8up snapshot lands in `homelab-backups/pelican` |

## Adding a second Wings node

One Wings daemon is one Panel "Node" and hosts many servers, so a second node is
only needed for a second machine. It is three changes, no new patterns:

1. A `terragrunt/proxmox/vm/wings-2/` directory and a `wings-2` entry in
   `inventory/hosts.yaml` under `games`.
2. A copy of `kubernetes/apps/pelican/wings-1.yaml` with the name, hostname and
   `EndpointSlice` address changed — the wildcard cert already covers it.
3. Register the Node in the Panel and re-run `composite/wings.yaml`.
