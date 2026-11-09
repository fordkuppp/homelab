# Blog: public Hugo site at blog.fordkuppp.me

Source is `github.com/fordkuppp/blog` (Hugo, Stack theme as a Hugo module).

```
push to blog/master
  └─ Actions: hugo --minify → image ghcr.io/fordkuppp/blog:<YYYYMMDDHHMMSS>-<sha7>
        (timestamp = commit time, UTC)
flux-system/ImageRepository blog   scans GHCR every 2m
flux-system/ImagePolicy blog       picks the highest timestamp
flux-system/ImageUpdateAutomation  rewrites the tag in apps/blog/deployment.yaml,
                                   pushes to homelab/main as fluxcdbot
root sync                          rolls out the Deployment
reader → Caddy (edge VPS, no Anubis) → Envoy https-public-blog → blog Service
```

Publishing a post is a push to the blog repo. Expect it live within ~5 minutes
of the image build finishing.

## Pieces

| Where | What |
| --- | --- |
| `kubernetes/apps/blog/` | Deployment (1× nginx-unprivileged, read-only root), Service, HTTPRoute, ImageRepository + ImagePolicy |
| `kubernetes/apps/image-automation/` | write-access GitRepository `homelab-write` (GitHub App auth), the app's credentials (ExternalSecret), the ImageUpdateAutomation. Shared: any future app can add an ImagePolicy in `flux-system` and a marker |
| `kubernetes/apps/gateway/gateway.yaml` | listener `https-public-blog`, exact hostname, cert `public-tls` |
| `kubernetes/apps/dns/records.yaml` | DNSEndpoint `public`: `blog.fordkuppp.me A 117.18.125.45`, proxy off |
| `ansible/roles/caddy_gateway/files/Caddyfile` | `blog.fordkuppp.me` site block |
| `renovate.json` | ignores `ghcr.io/fordkuppp/blog` so it never fights Flux |

## One-time setup

1. **GitHub App.** GitHub → Settings → Developer settings → GitHub Apps → New.
   Any name and homepage URL; untick **Webhook → Active**. Repository
   permissions: **Contents: Read and write** (Metadata: read-only is added
   automatically), nothing else. "Only on this account". Create it, note the
   **Client ID** (not the App ID), then **Generate a private key** (downloads a `.pem`).
   **Install App** → only select repositories → `homelab`.
   In Bitwarden Secrets Manager store `flux_github_app_client_id` (`Iv23…`) and
   `flux_github_app_private_key` (the whole `.pem`, BEGIN/END lines included).
   Delete the local `.pem`.
2. **First image.** Push the blog repo's CI changes. After the run, GHCR
   creates the package `blog` **private**; make it public (package settings →
   Change visibility). Flux scans anonymously and the kubelet pulls without a
   secret.
3. **Cluster.** Push homelab. Flux applies `image-automation` and `blog`; the
   first automation run replaces the placeholder tag in `deployment.yaml`.
4. **Edge.** `mise run ansible:edge:dry-run`, then `mise run ansible:edge`
   (or `ansible-playbook playbooks/caddy-gateway.yaml`).

## Verify

```sh
kubectl -n flux-system get externalsecret homelab-github-app       # SecretSynced
kubectl -n flux-system get gitrepository homelab-write             # READY True
kubectl -n flux-system get imagerepository,imagepolicy blog        # latest tag shown
kubectl -n flux-system get imageupdateautomation homelab           # last push time
kubectl -n tailscale get certificate public-tls                    # READY True
kubectl -n blog get pods
curl -sI https://blog.fordkuppp.me | head -1                       # 200
```

## When it breaks

- **Post pushed, site unchanged.** Walk the chain: Actions run green? Tag on
  GHCR? `imagepolicy blog` shows it? `imageupdateautomation homelab` pushed?
  A `homelab-write` auth error means the GitHub App: secrets missing from
  Bitwarden, the app not installed on `homelab`, or Contents not set to
  read and write (a permission change must also be accepted on the
  installation page before it takes effect).
- **ImagePolicy has no latest image.** Package still private, or a tag that
  doesn't match `^[0-9]{14}-[0-9a-f]{7}$` (the CI and `image.yaml` must agree).
- **Rollback.** Pin the tag by hand in `deployment.yaml` and suspend the
  automation (`flux suspend image update homelab`), or revert the post in the
  blog repo, which yields a newer tag with the old content.
