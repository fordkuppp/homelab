# Ansible

Configuration layer for hosts that are not managed by Flux. Layout follows
[`docs/structure.md`](../docs/structure.md): inventory, roles and playbooks all live
here. Per-concern playbooks sit at `playbooks/`;
composite (whole-machine) playbooks that chain them live in `playbooks/composite/`.

## Provision the whole edge box

`composite/edge.yml` runs the full stack on the `edge` group in order --
baseline hardening, the DERP relay, then the gateway (which no-ops until
`caddy_sites` is set):

```fish
cd ansible
ansible-playbook playbooks/composite/edge.yml \
  -e "tailscale_authkey=$(bws secret get $BWS_TS_DERP_AUTHKEY_ID | jq -r .value)"
```

It uses `import_playbook`, so each concern (`baseline.yml`, `tailscale-derp.yaml`,
`caddy-gateway.yaml`) stays runnable on its own too.

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
gateway can reach homelab services over the tailnet. The VPS has **two public
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
