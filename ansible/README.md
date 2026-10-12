# Ansible

Configuration layer for hosts that are not managed by Flux. Layout follows
[`docs/structure.md`](../docs/structure.md): inventory lives at the repo root,
roles and playbooks live here.

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
