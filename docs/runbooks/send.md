# Send: public file sharing at share.app.fordkuppp.me

Upload a file, get a link that dies after N downloads or a deadline. Uploading
needs a Pocket ID login (so only you can fill the disk); downloading is open to
anyone with the link. Design and reasoning:
`docs/superpowers/specs/2026-11-04-send-public-share-design.md`.

Everything is declarative except the OIDC client, which Pocket ID has no API
to bootstrap, and the NFS directory. Order matters: the secrets must exist
before Flux applies the app, and the DNS record must exist before Caddy can get
its certificate.

## 1. Pocket ID client

Admin → OIDC Clients → Add:

| Field | Value |
|---|---|
| Name | Send |
| Callback URL | `https://share.app.fordkuppp.me/oauth2/callback` |
| Logout callback URL | `https://share.app.fordkuppp.me/` |
| Public client | **off** -- Envoy holds a client secret |

The callback must match `redirectURL` in
`kubernetes/apps/send/securitypolicy.yaml` character for character. Put the
client ID and secret in Bitwarden Secrets Manager as `send_oidc_client_id` and
`send_oidc_client_secret`; the `send-oidc` ExternalSecret reads those names.

## 2. NFS directory on TrueNAS

The PV is static, so the directory has to exist, and the Send image runs as
uid 1000:

```fish
ssh root@192.168.1.11 'mkdir -p /mnt/general/data/send/uploads && chown 1000:1000 /mnt/general/data/send/uploads'
```

## 3. Merge and reconcile

Flux applies, in dependency order, the `*.app.fordkuppp.me` DNSEndpoint, the
`https-public` listener on the gateway (cert-manager then issues
`wildcard-app-tls`), and the app:

```fish
for k in dns gateway send
    flux --context homelab -n flux-system reconcile kustomization $k --with-source
end
kubectl --context homelab -n tailscale get certificate wildcard-app-tls   # READY True
kubectl --context homelab -n send get pods                                # 2/2 Running
```

The pod is `2/2` only once `/__heartbeat__` can reach the Valkey sidecar.

## 4. Provider firewall

Open `80/tcp` and `443/tcp` on `117.18.125.45` in the ReadyIDC security group.
Port 80 is for Caddy's ACME challenge; without it no certificate is issued and
the site serves nothing. A path that looks right but is unreachable is almost
always this.

## 5. Edge VPS: Anubis, then Caddy

```fish
cd ansible
ansible-playbook playbooks/anubis.yaml
ansible-playbook playbooks/caddy-gateway.yaml
```

The Caddy play rebuilds Caddy from source (caddy-l4 is still needed for
Minecraft), so Go must be on the controller. The Caddyfile is validated with
the custom binary before Caddy is reloaded.

## 6. Verify

| Check | Expectation |
|---|---|
| Anubis up | on the VPS: `curl -s http://127.0.0.1:9090/metrics \| head` |
| Caddy cert | `curl -vI https://share.app.fordkuppp.me 2>&1 \| grep subject` → Let's Encrypt, CN share.app.fordkuppp.me |
| Challenge | first browser visit from off-net shows the Anubis page briefly, then the app |
| Upload is gated | `https://share.app.fordkuppp.me/` from off-tailnet → redirect to `id.local.fordkuppp.me`, which does not resolve (expected: upload needs the tailnet) |
| Upload works | on the tailnet: log in via Pocket ID, upload a file, get a link |
| Download is open | open that link from mobile data: the download page loads with no login |
| One-shot | a second download of a 1-download link gives Send's "expired" page |
| Cleanup | `kubectl --context homelab -n send create job --from=cronjob/send-expired-uploads sweep-test && kubectl --context homelab -n send logs job/sweep-test`; delete the job after |

## Adding another public HTTP app

Three changes, no new patterns:

1. An HTTPRoute with hostname `<name>.app.fordkuppp.me` -- it attaches to the
   `https-public` listener by hostname. Add a `SecurityPolicy` if it needs a
   login.
2. A `caddy_sites` entry in `ansible/inventory/group_vars/edge.yaml` with
   `upstream: 192.168.1.3:443` and `tls: true`, then
   `ansible-playbook playbooks/caddy-gateway.yaml`. Anubis covers it
   automatically; add `anubis: false` to opt out.
3. Nothing for DNS: the `*.app.fordkuppp.me` wildcard already resolves it.
