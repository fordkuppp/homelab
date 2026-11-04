# Send public file sharing — design

Date: 2026-11-04
Status: approved, implemented on `feat/send-public-share`

## Goal

Share a file with anyone on the internet through a short-lived link that stops
working after N downloads or a deadline, without giving the world an anonymous
upload box. The app is [Send](https://github.com/timvisee/send) (timvisee's
fork of Firefox Send) at `https://share.app.fordkuppp.me`. Uploading requires a
Pocket ID login; downloading never does.

This is also the first public **HTTP** app, so it settles the pattern for every
one after it: the edge VPS gets a reusable `*.app.fordkuppp.me` path into the
cluster's gateway, and an Anubis bot challenge in front of all of it.

## Topology

```
Internet
   │  https://share.app.fordkuppp.me  → 117.18.125.45  (caddy_bind_ip)
   ▼
edge VPS  derp-bkk-01
   caddy  :443  terminates public TLS (its own Let's Encrypt cert)
          ├─ forward_auth → anubis@caddy  127.0.0.1:8923   (verdict only)
          │                 401 → challenge page at /.within.website/
          └─ reverse_proxy https://192.168.1.3:443, SNI share.app.fordkuppp.me
                │
                │  tailnet (subnet route 192.168.1.3/32)
                ▼
k3s  Envoy gateway, listener `https-public` *.app.fordkuppp.me, wildcard-app-tls
          ├─ HTTPRoute send-upload  (/, /api/ws, /api/upload, /oauth2/callback, /logout)
          │     SecurityPolicy OIDC → Pocket ID (id.local.fordkuppp.me)
          └─ HTTPRoute send         (everything else: download page, blob API, assets)
                │
                ▼
     pod send: send:1443 + valkey sidecar (127.0.0.1:6379)
          uploads  → NFS 192.168.1.11:/mnt/general/data/send/uploads
          valkey   → local-path PVC
     CronJob send-expired-uploads, 03:30 daily
```

## Decisions

### D1 — Send, not Gokapi or Pingvin

The ask was "upload, get a one-shot link". Send is exactly that and nothing
more: no accounts, no admin UI, client-side encryption so the server only ever
holds ciphertext, expiry by download count and by time, optional password.
Gokapi and Pingvin Share bring an admin surface and user management this use
case does not need. The missing piece -- who may upload -- is solved at the
gateway (D4) instead of inside the app.

### D2 — Public HTTP enters through Caddy, re-encrypted to Envoy

The homelab is behind CGNAT; the only public entry is the Bangkok VPS, where
Caddy already owns `:443` on the second IP. Caddy terminates the public TLS and
proxies to the cluster's Envoy gateway over the tailnet.

The gateway previously listened only for `*.local.fordkuppp.me`, and its port-80
listener redirects to HTTPS, so Caddy had nowhere to land. Two ways to add the
public listener were weighed:

| | HTTPS listener (chosen) | plain-HTTP listener |
|---|---|---|
| Caddy → Envoy | TLS, SNI = site host, cert checked | plain HTTP inside WireGuard |
| Envoy's OIDC filter | sees HTTPS natively; documented path | must trust `X-Forwarded-Proto` from Caddy (a ClientTrafficPolicy and a second trust boundary) |
| Certificates | cert-manager issues `wildcard-app-tls` from the Gateway annotation, like the local wildcard | none |
| Cost | one extra TLS hop on a tiny box | none |

The double TLS is cheap; a header-trust rule that silently decides whether
login works is not. Caddy's `reverse_proxy https://<ip>` with an explicit
`tls_server_name` gives a verified hop with the hostname as SNI, so Envoy routes
it like any other HTTPS request.

A separate Tailscale LoadBalancer per public app was considered and rejected:
it bypasses the gateway, so each app would need its own TLS and auth story, and
it leaves one more tailnet device per app to manage.

### D3 — `*.app.fordkuppp.me` wildcard, Cloudflare proxy off

Mirrors `*.games`: a `DNSEndpoint` for the wildcard, so the second public app
needs no DNS change at all. Grey cloud because Caddy runs its own ACME on that
IP, and because the free Cloudflare proxy caps request bodies at 100 MB, which
would break the app's reason to exist.

### D4 — Uploads gated by OIDC at the gateway, downloads open

Send has no concept of users. Exposed as-is, anyone could use the TrueNAS pool
as a free file host, which is the kind of thing that gets a domain blacklisted.

Envoy Gateway's `SecurityPolicy` runs the OIDC code flow against Pocket ID, and
it attaches per HTTPRoute. So the hostname is split into two routes:

- `send-upload` -- exact matches on the paths that create content: `/` (the
  upload page), `/api/ws` (the websocket the browser streams the file over),
  `/api/upload` (the legacy POST), plus `/oauth2/callback` and `/logout` for
  the filter itself. The policy targets this route.
- `send` -- a `/` prefix catch-all: `/download/:id`, `/api/metadata`,
  `/api/download`, the static bundle, the owner-token management calls. No
  policy.

Gateway API ranks exact matches above prefix matches, so the split is
deterministic. A recipient opens `/download/…` and never meets a login page.

Pocket ID is reachable only on the LAN and tailnet, which means the login page
is too. That is the right set: the people who may upload are the people who
are already on the tailnet.

### D5 — Anubis in front of every Caddy HTTP site, in subrequest mode

Anubis sits between Caddy and the public, but as a *verdict* service rather
than a proxy. Caddy's `forward_auth` asks `/.within.website/x/cmd/anubis/api/check`;
a 401 sends the visitor to the challenge page, which Caddy serves from the same
hostname by proxying the `/.within.website/` prefix to Anubis. Nothing else
changes hands, so one instance covers every site and adding a site is still one
`caddy_sites` entry.

The alternative, Anubis's default reverse-proxy mode, needs one Anubis per
upstream (or a second Caddy tier) and would put Anubis on the TLS path to Envoy.

Two upstream defaults are overridden because they are wrong for this mode:
`DENY` returns 403 (a 200 from the check endpoint means "allow"), and
`REDIRECT_DOMAINS` is set to the site list (unset, the post-challenge redirect
is open). Game servers are raw TCP and are untouched.

Anubis is installed from upstream's `.deb` as a native systemd template unit,
the same shape as derper and Caddy on that box: no container runtime on the
VPS.

### D6 — Valkey as a sidecar, uploads on NFS, nothing backed up

Send keeps one Redis hash per upload with the expiry as the key TTL. Valkey
runs as a second container in the Send pod: Send is its only client, they talk
over localhost, and neither has a reason to restart without the other. Its
append-only log lives on a `local-path` PVC.

Uploads go to TrueNAS (`general/data/send/uploads`) because 2 GB files add up
and the node disk is small.

The namespace is deliberately **not** labelled for k8up. Everything in it lives
at most seven days, so a restore could only ever bring back files that had
already lapsed.

### D7 — A CronJob sweeps expired files

Send's filesystem backend never deletes an expired upload. The Valkey hash
expires and the link dies, but the file stays on disk; only the download-limit
path unlinks. Left alone, the share would fill with ciphertext nobody can open.

Send names files `<expiry-days>-<id>`, with the expiry rounded down to whole
days (minimum 1), so the name says when a file lapsed. A daily busybox CronJob
deletes each file older than its own prefix. `find -mtime +N` only matches files
at least N+1 days old, so the sweep is always a little late and never early.

## Out of scope / human steps

See `docs/runbooks/send.md`: the Pocket ID client, the two Bitwarden secrets,
the NFS directory, the provider firewall on the second IP for 80/443, and the
Ansible run against the VPS. Nothing deploys until this branch merges.
