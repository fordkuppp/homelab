# Pelican game panel — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up Pelican as the homelab's game-server control plane — Panel in k3s, Wings on a dedicated Proxmox VM — with a Minecraft server reachable from the public internet.

**Architecture:** The Panel is a normal Flux-managed app behind the existing Envoy gateway, storing state in SQLite on a `local-path` PVC. Wings runs on its own VM at `192.168.1.30` with `tailscaled`, exposed to the browser through the gateway using the selector-less `Service` + `EndpointSlice` pattern already used for Proxmox and TrueNAS. Public Minecraft traffic enters at the Bangkok edge VPS, where a `caddy-l4`-enabled Caddy forwards raw TCP over the tailnet.

**Tech Stack:** OpenTofu/Terragrunt (Proxmox), Ansible, Flux + Kustomize, Envoy Gateway, cert-manager, k8up, Tailscale, Caddy + caddy-l4.

**Spec:** `docs/superpowers/specs/2026-11-02-pelican-minecraft-design.md`

---

## How to verify in this repo

There is no unit-test framework — this is infrastructure code. The equivalent of a failing test is a validator that rejects the tree. Use these, and treat "add the reference first, watch it fail, then add the file" as the red/green loop:

| Layer | Command |
|---|---|
| Kubernetes | `kustomize build kubernetes/apps/<app>/` then pipe to `kubeconform` (see Task 8) |
| Terragrunt | `terragrunt hcl validate --working-dir terragrunt/proxmox/vm/wings-1` |
| Ansible syntax | `ansible-playbook --syntax-check playbooks/<pb>.yaml` (run from `ansible/`) |
| Ansible dry run | `ansible-playbook --check --diff playbooks/<pb>.yaml` |
| Caddyfile | `/usr/local/bin/caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile` (on the VPS) |

CI (`.github/workflows/validate.yaml`) only runs the Kubernetes layer, so the others must be run locally.

## What this plan does NOT do

These need a human and are **out of scope for the code tasks**:

- Destroying `docker-1` to free `192.168.1.30` (spec P1).
- `terragrunt apply` — creating the VM.
- Running any playbook against a live host.
- Creating the `tag:games` tailnet auth key or any Bitwarden secret.
- The Panel install wizard and node registration.
- Opening `25565/tcp` in the ReadyIDC security group.

Tasks 1–14 write and validate the code. Task 15 is the human runbook for everything above, in order.

Note: the cluster's `FluxInstance` syncs `refs/heads/main`. Nothing deploys until this branch merges.

---

## File structure

**Create:**

| Path | Responsibility |
|---|---|
| `terragrunt/proxmox/vm/wings-1/terragrunt.hcl` | the VM |
| `ansible/roles/tailscale_node/{tasks,defaults}/main.yaml` | install + join tailscaled (extracted) |
| `ansible/roles/tailscale_derp/meta/main.yaml` | declares the dependency |
| `ansible/roles/pelican_wings/tasks/main.yaml` | install Wings |
| `ansible/roles/pelican_wings/defaults/main.yaml` | Wings knobs |
| `ansible/roles/pelican_wings/handlers/main.yaml` | restart wings |
| `ansible/roles/pelican_wings/templates/config.yml.j2` | `/etc/pelican/config.yml` |
| `ansible/roles/pelican_wings/templates/wings.service.j2` | systemd unit |
| `ansible/playbooks/pelican-wings.yaml` | per-concern play |
| `ansible/playbooks/composite/wings.yaml` | whole-machine play |
| `inventory/group_vars/games.yaml` | the `games` group's vars |
| `kubernetes/apps/pelican/*.yaml` | the Panel app + the Wings route |
| `kubernetes/flux/pelican.yaml` | Flux Kustomization |
| `kubernetes/apps/k8up-schedules/pelican.yaml` | Panel backup schedule |
| `docs/runbooks/pelican.md` | the manual steps |

**Modify:**

| Path | Change |
|---|---|
| `terragrunt/modules/proxmox-vm/variables.tf` | `user_data` gets a default |
| `terragrunt/modules/proxmox-vm/main.tf` | skip `user-data.sh` when empty |
| `ansible/roles/tailscale_derp/tasks/main.yaml` | remove the extracted tasks |
| `ansible/roles/tailscale_derp/defaults/main.yaml` | remove the extracted defaults |
| `ansible/roles/caddy_gateway/*` | custom build + layer4 |
| `ansible/playbooks/baseline.yaml` | parameterise `hosts` |
| `inventory/hosts.yaml` | the `games` group |
| `inventory/group_vars/edge.yaml` | `caddy_*` version pins + L4 route |
| `kubernetes/apps/k8up-schedules/kustomization.yaml` | add `pelican.yaml` |
| `kubernetes/flux/kustomization.yaml` | add `pelican.yaml` |
| `renovate.json` | three custom managers + a package rule |
| `docs/ip-plan.md` | rename the `.30–.39` range |
| `ansible/README.md` | document the new roles |

---

### Task 1: Make `user_data` optional in the proxmox-vm module

A VM whose configuration is entirely Ansible's job should not have to pass a dummy script. Today `user_data` has no default, so it must.

**Files:**
- Modify: `terragrunt/modules/proxmox-vm/variables.tf`
- Modify: `terragrunt/modules/proxmox-vm/main.tf`

- [x] **Step 1: Give the variable a default**

In `terragrunt/modules/proxmox-vm/variables.tf`, replace:

```hcl
variable "user_data" {
  type = string
  description = "Script to run when VM init"
}
```

with:

```hcl
variable "user_data" {
  type        = string
  description = "Script to run on first boot. Empty for VMs configured entirely by Ansible."
  default     = ""
}
```

- [x] **Step 2: Skip the script when it is empty**

In `terragrunt/modules/proxmox-vm/main.tf`, the cloud-init heredoc writes `/usr/local/bin/user-data.sh` and always runs it. Make both conditional. Replace:

```hcl
write_files:
  - path: /usr/local/bin/user-data.sh
    permissions: '0755'
    content: |
      ${indent(6, var.user_data)}
runcmd:
  - [systemctl, enable, qemu-guest-agent]
  - [systemctl, start, qemu-guest-agent]
  - [ sh, "/usr/local/bin/user-data.sh" ]
EOF
```

with:

```hcl
%{ if var.user_data != "" ~}
write_files:
  - path: /usr/local/bin/user-data.sh
    permissions: '0755'
    content: |
      ${indent(6, var.user_data)}
%{ endif ~}
runcmd:
  - [systemctl, enable, qemu-guest-agent]
  - [systemctl, start, qemu-guest-agent]
%{ if var.user_data != "" ~}
  - [ sh, "/usr/local/bin/user-data.sh" ]
%{ endif ~}
EOF
```

A template directive rather than a nested heredoc: HCL will not parse a
heredoc opened inside an interpolation that is itself inside a heredoc.

- [x] **Step 3: Verify the existing VMs still render identically**

Run:

```bash
terragrunt hcl validate --working-dir terragrunt/proxmox/vm/docker-1
terragrunt hcl validate --working-dir terragrunt/proxmox/vm/k3s-1
```

Expected: both exit 0. `docker-1` and `k3s-1` both pass a non-empty `user_data`, so their rendered cloud-init must be unchanged.

- [x] **Step 4: Commit**

```bash
git add terragrunt/modules/proxmox-vm/
git commit -m "Make proxmox-vm user_data optional

A VM configured entirely by Ansible has nothing to run on first boot and
should not have to pass a no-op script to satisfy a required variable."
```

---

### Task 2: Define the wings-1 VM

**Files:**
- Create: `terragrunt/proxmox/vm/wings-1/terragrunt.hcl`

- [x] **Step 1: Write the terragrunt config**

Modelled on `k3s-1/terragrunt.hcl`. No `user_data` — Task 1 made it optional.

```hcl
include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "proxmox" {
  path = find_in_parent_folders("proxmox.hcl")
}

terraform {
  source = "../../../modules/proxmox-vm"
}

dependency "ubuntu_image" {
  config_path = "../../images/vm/ubuntu2404"
}

locals {
  secrets = include.root.locals.secrets
}

# Pelican Wings host. Configured entirely by ansible/playbooks/composite/wings.yaml
# -- the cloud image already brings docker-ce and nfs-common, which is all Wings
# needs from the image.
inputs = {
  vm_name = "wings-1"
  vm_id   = 1201

  cpu_cores    = 4
  memory       = 8192
  disk_size_gb = 100
  disk_discard = "on"
  disk_ssd     = true

  cloud_image_id = dependency.ubuntu_image.outputs.file_id

  # Was docker-1's address; that VM is retired with Komodo. See docs/ip-plan.md.
  ip_address     = "192.168.1.30/24"
  on_boot        = true
  ssh_public_key = local.secrets.proxmox.ssh.default.public_key

  tags = ["games", "wings"]
}
```

- [x] **Step 2: Validate**

Run: `terragrunt hcl validate --working-dir terragrunt/proxmox/vm/wings-1`
Expected: exit 0, no output.

- [x] **Step 3: Commit**

```bash
git add terragrunt/proxmox/vm/wings-1/
git commit -m "Add the wings-1 VM

4c/8G/100G at 192.168.1.30, taking the address docker-1 vacates."
```

---

### Task 3: Extract the `tailscale_node` role

`tailscale_derp/tasks/main.yaml` lines 2–50 are generic "install tailscaled and join the tailnet". The Wings VM needs exactly that. Extract rather than copy.

**Files:**
- Create: `ansible/roles/tailscale_node/tasks/main.yaml`
- Create: `ansible/roles/tailscale_node/defaults/main.yaml`
- Create: `ansible/roles/tailscale_derp/meta/main.yaml`
- Modify: `ansible/roles/tailscale_derp/tasks/main.yaml`
- Modify: `ansible/roles/tailscale_derp/defaults/main.yaml`

- [x] **Step 1: Create the new role's tasks**

`ansible/roles/tailscale_node/tasks/main.yaml` — moved verbatim from `tailscale_derp`:

```yaml
---
- name: Fail fast when the Tailscale auth key is missing
  ansible.builtin.assert:
    that:
      - tailscale_authkey | length > 0
    fail_msg: >-
      tailscale_authkey is unset. Create a TAGGED pre-auth key in the Tailscale
      admin console, store it in Bitwarden Secrets Manager, and pass it at run
      time: -e "tailscale_authkey=$(bws secret get $BWS_TS_AUTHKEY_ID | jq -r .value)".

- name: Install Tailscale via the official script
  ansible.builtin.shell:
    cmd: curl -fsSL https://tailscale.com/install.sh | sh
    creates: /usr/bin/tailscale

- name: Enable and start tailscaled
  ansible.builtin.systemd:
    name: tailscaled
    enabled: true
    state: started

- name: Check tailnet connection state
  ansible.builtin.command:
    cmd: tailscale status --json
  register: tailscale_status
  changed_when: false
  failed_when: false

- name: Join the tailnet
  ansible.builtin.command:
    cmd: "tailscale up --authkey={{ tailscale_authkey }} {{ tailscale_up_args }}"
  when: >-
    tailscale_status.rc != 0
    or (tailscale_status.stdout | from_json).BackendState | default('') != 'Running'
  no_log: true
  register: tailscale_up
  changed_when: tailscale_up.rc == 0

# `tailscale up` only runs on first join, so reconcile the mutable prefs on
# every run via `tailscale set` -- this is how a later accept-routes flip
# actually takes effect without re-authing.
- name: Reconcile tailnet preferences
  ansible.builtin.command:
    cmd: >-
      tailscale set
      --accept-dns=false
      --accept-routes={{ 'true' if tailscale_accept_routes else 'false' }}
      --ssh=false
  changed_when: false

- name: Record this node's tailnet IPv4
  ansible.builtin.command:
    cmd: tailscale ip -4
  register: tailscale_ip
  changed_when: false

- name: Expose the tailnet IPv4 as a fact
  ansible.builtin.set_fact:
    tailscale_ipv4: "{{ tailscale_ip.stdout_lines[0] }}"
```

The last two tasks are new: the Caddy L4 upstream needs this node's tailnet address, and printing it beats looking it up by hand.

- [x] **Step 2: Create the new role's defaults**

`ansible/roles/tailscale_node/defaults/main.yaml` — the `--- Tailscale node ---` half of the derp role's defaults:

```yaml
---
# Required. A tagged pre-auth key OR an OAuth client secret (tskey-client-...,
# non-expiring), passed at run time (see inventory/group_vars/).
tailscale_authkey: ""
tailscale_hostname: "{{ inventory_hostname }}"
# Tags advertised on join. REQUIRED when authing with an OAuth client secret
# (must be a subset of the client's tags); harmless with a tagged pre-auth key.
tailscale_tags: ""
# Off by default. The edge node flips it on so the co-located Caddy gateway can
# reach the homelab; a node already ON the LAN must leave it off, or it learns
# routes to the network it is already sitting on.
tailscale_accept_routes: false
tailscale_up_args: >-
  --accept-dns=false
  --accept-routes={{ 'true' if tailscale_accept_routes else 'false' }}
  --ssh=false --hostname={{ tailscale_hostname }}
  {{ ('--advertise-tags=' ~ tailscale_tags) if tailscale_tags else '' }}
```

- [x] **Step 3: Declare the dependency from `tailscale_derp`**

Create `ansible/roles/tailscale_derp/meta/main.yaml`:

```yaml
---
# derper needs a local tailscaled to --verify-clients against the tailnet.
dependencies:
  - role: tailscale_node
```

- [x] **Step 4: Remove the extracted tasks from `tailscale_derp`**

In `ansible/roles/tailscale_derp/tasks/main.yaml`, delete everything from `- name: Fail fast when the Tailscale auth key is missing` through the end of `- name: Reconcile tailnet preferences` (lines 2–50). The file now begins:

```yaml
---
# --- derper binary (built on the controller, shipped to the VPS) ---
# Tailscale ships no derper package or binary, so it's built from source. That
# compile is slow and network-flaky on a 1-core VPS, so build it once on the
# controller (where there's CPU/RAM + a reliable uplink) and copy the static
# binary over. Requires Go on the controller.
- name: Create the derper state directory
```

Leave everything from that task onward untouched.

- [x] **Step 5: Remove the extracted defaults from `tailscale_derp`**

In `ansible/roles/tailscale_derp/defaults/main.yaml`, delete the block from `# --- Tailscale node ---` through the `tailscale_up_args` definition. The file now begins:

```yaml
---
# --- DERP relay (derper) ---
derp_hostname: "derp.example.com"
```

- [x] **Step 6: Verify the derp playbook still resolves**

Run from the `ansible/` directory:

```bash
cd ansible && ansible-playbook --syntax-check playbooks/tailscale-derp.yaml
```

Expected: `playbook: playbooks/tailscale-derp.yaml`, exit 0. A syntax check resolves role dependencies, so a missing `tailscale_node` or a typo in `meta/main.yaml` fails here.

- [x] **Step 7: Verify the composite edge playbook still resolves**

```bash
cd ansible && ansible-playbook --syntax-check playbooks/composite/edge.yaml
```

Expected: exit 0.

- [x] **Step 8: Commit**

```bash
git add ansible/roles/tailscale_node/ ansible/roles/tailscale_derp/
git commit -m "Extract a tailscale_node role from tailscale_derp

The Wings VM needs the same install-and-join logic. Extract it rather than
copy it; tailscale_derp now depends on it and keeps only the derper half.
Also records the node's tailnet IPv4 as a fact, which the Caddy L4 upstream
needs."
```

---

### Task 4: The `pelican_wings` role

**Files:**
- Create: `ansible/roles/pelican_wings/defaults/main.yaml`
- Create: `ansible/roles/pelican_wings/tasks/main.yaml`
- Create: `ansible/roles/pelican_wings/handlers/main.yaml`
- Create: `ansible/roles/pelican_wings/templates/config.yml.j2`
- Create: `ansible/roles/pelican_wings/templates/wings.service.j2`

- [x] **Step 1: Defaults**

`ansible/roles/pelican_wings/defaults/main.yaml`:

```yaml
---
# Pinned; Renovate tracks pelican/wings releases.
pelican_wings_version: "v1.0.0-rc.1"
pelican_wings_arch: amd64
pelican_wings_bin: /usr/local/bin/wings

# Wings' own defaults for these paths; named here because the role creates them
# and because backup_directory is an NFS mount point.
pelican_wings_config_dir: /etc/pelican
pelican_wings_root: /var/lib/pelican
pelican_wings_data: "{{ pelican_wings_root }}/volumes"
pelican_wings_backup_dir: "{{ pelican_wings_root }}/backups"

# Node credentials. Generated by the Panel when the Node is created -- there is
# no API to bootstrap them. Store in Bitwarden and pass at run time:
#   -e "pelican_node_uuid=... pelican_node_token_id=... pelican_node_token=..."
pelican_node_uuid: ""
pelican_node_token_id: ""
pelican_node_token: ""

pelican_panel_url: "https://panel.local.fordkuppp.me"
pelican_wings_fqdn: "wings-1.local.fordkuppp.me"

# Wings sits behind the Envoy gateway. flannel masquerades pod egress leaving
# the cluster, so requests arrive from the k3s NODE address, not the pod CIDR.
pelican_wings_trusted_proxies:
  - "192.168.1.20/32"

# Max upload size through the file manager, in MiB.
pelican_wings_upload_limit: 1024

# Game-server backups land on the TrueNAS `general/backup` dataset, which
# already has a daily snapshot task on a 14-day lifetime.
pelican_backup_nfs_server: "192.168.1.11"
pelican_backup_nfs_export: "/mnt/general/backup"
```

- [x] **Step 2: Handlers**

`ansible/roles/pelican_wings/handlers/main.yaml`:

```yaml
---
- name: Reload systemd
  ansible.builtin.systemd:
    daemon_reload: true

- name: Restart wings
  ansible.builtin.systemd:
    name: wings
    state: restarted
```

- [x] **Step 3: Tasks**

`ansible/roles/pelican_wings/tasks/main.yaml`:

```yaml
---
- name: Fail fast on missing node credentials
  ansible.builtin.assert:
    that:
      - pelican_node_uuid | length > 0
      - pelican_node_token_id | length > 0
      - pelican_node_token | length > 0
    fail_msg: >-
      Node credentials are unset. The Panel generates them when you create the
      Node (Admin -> Nodes -> Create); there is no API to bootstrap them cold.
      Store them in Bitwarden and pass at run time -- see docs/runbooks/pelican.md.

- name: Create the Wings directories
  ansible.builtin.file:
    path: "{{ item }}"
    state: directory
    owner: root
    group: root
    mode: "0700"
  loop:
    - "{{ pelican_wings_config_dir }}"
    - "{{ pelican_wings_root }}"
    - "{{ pelican_wings_data }}"
    - "{{ pelican_wings_backup_dir }}"

# Backups go straight to TrueNAS so world data outlives the VM. `soft` so a NAS
# outage stalls backups instead of wedging every process that touches the path.
- name: Mount the TrueNAS backup share at Wings' backup directory
  ansible.posix.mount:
    path: "{{ pelican_wings_backup_dir }}"
    src: "{{ pelican_backup_nfs_server }}:{{ pelican_backup_nfs_export }}"
    fstype: nfs
    opts: "rw,soft,nfsvers=4,_netdev"
    state: mounted

- name: Install the Wings binary
  ansible.builtin.get_url:
    url: >-
      https://github.com/pelican/wings/releases/download/{{ pelican_wings_version }}/wings_linux_{{ pelican_wings_arch }}
    dest: "{{ pelican_wings_bin }}"
    owner: root
    group: root
    mode: "0755"
  notify: Restart wings

- name: Render the Wings configuration
  ansible.builtin.template:
    src: config.yml.j2
    dest: "{{ pelican_wings_config_dir }}/config.yml"
    owner: root
    group: root
    mode: "0600"
  no_log: true # carries the node token
  notify: Restart wings

- name: Install the wings systemd unit
  ansible.builtin.template:
    src: wings.service.j2
    dest: /etc/systemd/system/wings.service
    owner: root
    group: root
    mode: "0644"
  notify:
    - Reload systemd
    - Restart wings

- name: Enable and start wings
  ansible.builtin.systemd:
    name: wings
    enabled: true
    state: started

- name: Next steps -- wire this node into the public gateway
  ansible.builtin.debug:
    msg:
      - "Wings API (via the cluster gateway): https://{{ pelican_wings_fqdn }}"
      - "Tailnet IPv4 of this node: {{ tailscale_ipv4 | default('unknown -- run the tailscale_node role') }}"
      - "Set this in inventory/group_vars/edge.yaml so Caddy can forward Minecraft:"
      - >-
        caddy_l4_routes:
          - listen_port: 25565
            upstream: "{{ tailscale_ipv4 | default('<tailnet-ip>') }}:25565"
      - "Then: ansible-playbook playbooks/caddy-gateway.yaml"
```

- [x] **Step 4: The systemd unit template**

`ansible/roles/pelican_wings/templates/wings.service.j2` — from the Pelican docs:

```jinja
{{ ansible_managed | comment }}
[Unit]
Description=Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory={{ pelican_wings_config_dir }}
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart={{ pelican_wings_bin }}
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
```

- [x] **Step 5: The config template**

`ansible/roles/pelican_wings/templates/config.yml.j2`. Keys verified against `config/config.go` in `pelican/wings`:

```jinja
{{ ansible_managed | comment }}
debug: false
uuid: {{ pelican_node_uuid }}
token_id: {{ pelican_node_token_id }}
token: {{ pelican_node_token }}

api:
  host: 0.0.0.0
  port: 8080
  # TLS is terminated by the Envoy gateway in front of this node, so Wings
  # itself speaks plain HTTP. See the spec, decision D2.
  ssl:
    enabled: false
  upload_limit: {{ pelican_wings_upload_limit }}
  trusted_proxies:
{% for cidr in pelican_wings_trusted_proxies %}
    - "{{ cidr }}"
{% endfor %}

system:
  root_directory: {{ pelican_wings_root }}
  data: {{ pelican_wings_data }}
  backup_directory: {{ pelican_wings_backup_dir }}
  username: pelican
  timezone: Asia/Bangkok
  sftp:
    bind_address: 0.0.0.0
    bind_port: 2022

remote: {{ pelican_panel_url }}

allowed_origins:
  - "{{ pelican_panel_url }}"
```

- [x] **Step 6: Verify the templates are valid Jinja and YAML**

There is no host to run against yet, so render the config template standalone:

```bash
cd ansible && python3 -c "
import jinja2, yaml, pathlib
src = pathlib.Path('roles/pelican_wings/templates/config.yml.j2').read_text()
out = jinja2.Template(src).render(
    ansible_managed='Ansible managed',
    pelican_node_uuid='00000000-0000-0000-0000-000000000000',
    pelican_node_token_id='abcd1234',
    pelican_node_token='secret',
    pelican_wings_upload_limit=1024,
    pelican_wings_trusted_proxies=['192.168.1.20/32'],
    pelican_wings_root='/var/lib/pelican',
    pelican_wings_data='/var/lib/pelican/volumes',
    pelican_wings_backup_dir='/var/lib/pelican/backups',
    pelican_panel_url='https://panel.local.fordkuppp.me',
)
yaml.safe_load(out)
print(out)
"
```

Expected: the rendered config prints with no traceback. A YAML error or an undefined variable fails here.

Note `ansible_managed | comment` renders a `#`-prefixed block, so the output stays valid YAML.

- [x] **Step 7: Commit**

```bash
git add ansible/roles/pelican_wings/
git commit -m "Add the pelican_wings role

Installs the pinned Wings binary, mounts the TrueNAS backup dataset at
Wings' backup_directory so world data outlives the VM, and templates
config.yml from node credentials passed at run time.

Wings runs plain HTTP; the Envoy gateway terminates TLS in front of it.
trusted_proxies is the k3s node address, not the pod CIDR -- flannel
masquerades pod egress leaving the cluster."
```

---

### Task 5: Inventory — the `games` group

**Files:**
- Modify: `inventory/hosts.yaml`
- Create: `inventory/group_vars/games.yaml`

- [x] **Step 1: Add the group**

Append to `inventory/hosts.yaml`, inside `all.children`:

```yaml
    # Pelican Wings host. Runs the game containers; the Panel lives in k3s.
    # On the LAN, plus a tailnet node of its own so the Bangkok edge VPS can
    # forward Minecraft traffic to it without routing through the cluster's
    # subnet router.
    games:
      hosts:
        wings-1:
          ansible_host: 192.168.1.30
          ansible_user: ubuntu
```

- [x] **Step 2: Add the group vars**

`inventory/group_vars/games.yaml`:

```yaml
---
# Wings host. Unlike the edge VPS this box is already ON the LAN, so it joins
# the tailnet purely to be reachable from Bangkok -- it must NOT accept the
# homelab subnet routes it is already sitting inside.
tailscale_accept_routes: false
tailscale_tags: "tag:games"

# Tagged pre-auth key. NEVER commit -- pass at run time:
#   ansible-playbook playbooks/composite/wings.yaml \
#     -e "tailscale_authkey=$(bws secret get $BWS_TS_GAMES_AUTHKEY_ID | jq -r .value)"
tailscale_authkey: "" # runtime only

# Node credentials from the Panel. Runtime only, same handling. See
# docs/runbooks/pelican.md for where they come from.
pelican_node_uuid: ""
pelican_node_token_id: ""
pelican_node_token: ""

# Become via sudo; the cloud image's `ubuntu` user is a passwordless sudoer.
ansible_become: true
```

- [x] **Step 3: Verify the inventory parses and the group resolves**

```bash
cd ansible && ansible-inventory --list --yaml | grep -A4 "games:"
```

Expected: the `games` group appears with `wings-1` and `ansible_host: 192.168.1.30`.

- [x] **Step 4: Commit**

```bash
git add inventory/
git commit -m "Add the games inventory group with wings-1"
```

---

### Task 6: Playbooks

**Files:**
- Modify: `ansible/playbooks/baseline.yaml`
- Create: `ansible/playbooks/pelican-wings.yaml`
- Create: `ansible/playbooks/composite/wings.yaml`

- [x] **Step 1: Parameterise baseline's target**

`ansible/playbooks/baseline.yaml` hardcodes `hosts: edge`. Replace the file with:

```yaml
---
# Host baseline: key-only SSH, conffile-safe unattended security upgrades, and
# fail2ban. Defaults to the internet-facing edge VPS; composite playbooks for
# other groups override baseline_hosts.
- name: Baseline host hardening
  hosts: "{{ baseline_hosts | default('edge') }}"
  become: true
  roles:
    - baseline
```

`composite/edge.yaml` keeps working untouched because the default is `edge`.

- [x] **Step 2: The per-concern play**

`ansible/playbooks/pelican-wings.yaml`:

```yaml
---
# Pelican Wings: the daemon that owns the game containers. The Panel lives in
# k3s (kubernetes/apps/pelican); this is the other half.
- name: Pelican Wings host
  hosts: games
  become: true
  roles:
    - tailscale_node
    - pelican_wings
```

- [x] **Step 3: The composite play**

`ansible/playbooks/composite/wings.yaml`:

```yaml
---
# Provision the whole Wings VM in one run: harden the host, then install
# tailscaled and Wings. import_playbook paths are relative to this file, so
# ../ points back to the playbooks root.
- import_playbook: ../baseline.yaml
  vars:
    baseline_hosts: games
- import_playbook: ../pelican-wings.yaml
```

- [x] **Step 4: Syntax-check all three**

```bash
cd ansible && ansible-playbook --syntax-check \
  playbooks/baseline.yaml \
  playbooks/pelican-wings.yaml \
  playbooks/composite/wings.yaml \
  playbooks/composite/edge.yaml
```

Expected: exit 0, each playbook listed. This resolves roles and `import_playbook` paths, so a missing role or a bad relative path fails here.

- [x] **Step 5: Commit**

```bash
git add ansible/playbooks/
git commit -m "Add the wings playbooks; parameterise baseline's target

baseline defaulted to hosts: edge. It now takes baseline_hosts so the
Wings composite can harden the games group with the same role."
```

---

### Task 7: Teach `caddy_gateway` layer 4

The largest change to existing code. Stock apt Caddy cannot proxy raw TCP; Minecraft needs `caddy-l4`, which means a custom `xcaddy` build.

**Files:**
- Modify: `ansible/roles/caddy_gateway/defaults/main.yaml`
- Modify: `ansible/roles/caddy_gateway/tasks/main.yaml`
- Modify: `ansible/roles/caddy_gateway/templates/Caddyfile.j2`
- Create: `ansible/roles/caddy_gateway/templates/systemd-override.conf.j2`
- Modify: `inventory/group_vars/edge.yaml`

- [x] **Step 1: Add the new defaults**

Append to `ansible/roles/caddy_gateway/defaults/main.yaml`:

```yaml

# --- Layer 4 (raw TCP) routes ---
# Stock Caddy only speaks HTTP. Game protocols like Minecraft are raw TCP, which
# needs the caddy-l4 module and therefore a custom xcaddy build (see tasks).
# Each entry: a port to listen on (bound to caddy_bind_ip) and an upstream this
# node can reach over the tailnet.
#   caddy_l4_routes:
#     - listen_port: 25565
#       upstream: 100.64.0.5:25565
caddy_l4_routes: []

# --- Custom build (cross-compiled on the Ansible controller; needs Go there) ---
# Pinned so a rebuild is reproducible and Renovate can propose bumps. The apt
# package stays installed for its unit, its `caddy` user and /etc/caddy; a
# systemd drop-in points ExecStart at the custom binary so an apt upgrade can
# never silently restore a plugin-less Caddy.
caddy_version: "v2.11.7"
caddy_l4_version: "v0.1.2"
caddy_custom_bin: /usr/local/bin/caddy
caddy_build_goos: linux
caddy_build_goarch: amd64
```

- [x] **Step 2: Relax the assert and pin the validator**

In `ansible/roles/caddy_gateway/tasks/main.yaml`, replace the first task:

```yaml
- name: Fail fast on missing gateway config
  ansible.builtin.assert:
    that:
      - caddy_bind_ip | length > 0
      - caddy_sites | length > 0
    fail_msg: >-
      Set caddy_bind_ip (the VPS's second public IP) and at least one entry in
      caddy_sites in inventory/group_vars/edge.yaml.
```

with:

```yaml
- name: Fail fast on missing gateway config
  ansible.builtin.assert:
    that:
      - caddy_bind_ip | length > 0
      - (caddy_sites | length > 0) or (caddy_l4_routes | length > 0)
    fail_msg: >-
      Set caddy_bind_ip (the VPS's second public IP) and at least one entry in
      caddy_sites or caddy_l4_routes in inventory/group_vars/edge.yaml.
```

A game-server forward is a legitimate reason to run this role with no HTTP sites at all.

- [x] **Step 3: Build the custom binary on the controller**

In the same file, insert these tasks immediately after `- name: Install Caddy` (the apt task) and before `- name: Render the Caddyfile`:

```yaml
# --- Custom binary with caddy-l4 (built on the controller, shipped to the VPS) ---
# Same reasoning as derper: the VPS is a 1-core box, so compile where there is
# CPU and a reliable uplink. Requires Go on the controller.
- name: Install xcaddy on the controller
  delegate_to: localhost
  run_once: true
  become: false
  ansible.builtin.command:
    cmd: go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
  changed_when: false

- name: Resolve the controller's Go build paths
  delegate_to: localhost
  run_once: true
  become: false
  ansible.builtin.command:
    cmd: go env GOPATH
  register: caddy_go_env
  changed_when: false

- name: Build Caddy with caddy-l4 for {{ caddy_build_goos }}/{{ caddy_build_goarch }}
  delegate_to: localhost
  run_once: true
  become: false
  ansible.builtin.command:
    cmd: >-
      {{ caddy_go_env.stdout }}/bin/xcaddy build {{ caddy_version }}
      --with github.com/mholt/caddy-l4@{{ caddy_l4_version }}
      --output {{ caddy_build_tmp }}
  environment:
    GOOS: "{{ caddy_build_goos }}"
    GOARCH: "{{ caddy_build_goarch }}"
  vars:
    caddy_build_tmp: "/tmp/caddy-{{ caddy_version }}-l4-{{ caddy_l4_version }}"
  changed_when: false

- name: Create the caddy systemd drop-in directory
  ansible.builtin.file:
    path: /etc/systemd/system/caddy.service.d
    state: directory
    owner: root
    group: root
    mode: "0755"

- name: Ship the custom Caddy binary to the VPS
  ansible.builtin.copy:
    src: "/tmp/caddy-{{ caddy_version }}-l4-{{ caddy_l4_version }}"
    dest: "{{ caddy_custom_bin }}"
    owner: root
    group: root
    mode: "0755"
  notify: Restart Caddy

- name: Point the systemd unit at the custom binary
  ansible.builtin.template:
    src: systemd-override.conf.j2
    dest: /etc/systemd/system/caddy.service.d/10-custom-binary.conf
    owner: root
    group: root
    mode: "0644"
  notify:
    - Reload systemd
    - Restart Caddy
```

- [x] **Step 4: Pin the Caddyfile validator to the custom binary**

Still in `tasks/main.yaml`, the render task currently validates with whatever `caddy` is on `PATH` — the apt build, which rejects `layer4`. Replace:

```yaml
    validate: "caddy validate --adapter caddyfile --config %s"
```

with:

```yaml
    validate: "{{ caddy_custom_bin }} validate --adapter caddyfile --config %s"
```

- [x] **Step 5: Add the `Reload systemd` handler**

`ansible/roles/caddy_gateway/handlers/main.yaml` has a `Reload Caddy`/`Restart Caddy` handler but no systemd reload. Append:

```yaml

- name: Reload systemd
  ansible.builtin.systemd:
    daemon_reload: true
```

Read the existing handler file first and keep its contents; only append.

- [x] **Step 6: The systemd override template**

`ansible/roles/caddy_gateway/templates/systemd-override.conf.j2`:

```jinja
{{ ansible_managed | comment }}
# The apt package provides the unit, the `caddy` user and /etc/caddy, but its
# binary has no caddy-l4 and cannot parse the layer4 block. Point the unit at
# the custom build instead, so an apt upgrade of the package cannot silently
# revert us to a Caddy that drops every Minecraft connection.
[Service]
ExecStart=
ExecStart={{ caddy_custom_bin }} run --environ --config /etc/caddy/Caddyfile
ExecReload=
ExecReload={{ caddy_custom_bin }} reload --config /etc/caddy/Caddyfile --force
```

The empty assignments are required: systemd appends to `ExecStart` lists otherwise.

- [x] **Step 7: Add the layer4 block to the Caddyfile**

Replace `ansible/roles/caddy_gateway/templates/Caddyfile.j2` with:

```jinja
{{ ansible_managed | comment }}
{
	email {{ caddy_email }}
	# Keep every listener (incl. the :80 ACME/redirect vhost) on the second
	# IP so Caddy never touches derper's :443 on the first IP.
	default_bind {{ caddy_bind_ip }}
{% if caddy_l4_routes %}

	# Raw TCP (game servers). default_bind does NOT apply to layer4 listeners,
	# so the bind IP is explicit -- otherwise these listen on 0.0.0.0 and spill
	# onto derper's IP.
	layer4 {
{% for route in caddy_l4_routes %}
		{{ caddy_bind_ip }}:{{ route.listen_port }} {
			route {
				proxy {{ route.upstream }}
			}
		}
{% endfor %}
	}
{% endif %}
}

{% for site in caddy_sites %}
{{ site.host }} {
	reverse_proxy {{ site.upstream }}
}
{% endfor %}
```

- [x] **Step 8: Declare the route in the edge group vars**

In `inventory/group_vars/edge.yaml`, append:

```yaml

# --- Raw TCP forwards (game servers) ---
# Minecraft is not HTTP, so this needs the caddy-l4 module -- the role builds a
# custom Caddy for it. The upstream is wings-1's TAILNET address, not its LAN
# address: the VPS reaches it peer-to-peer, keeping the k8s subnet router out
# of the player data path. The pelican_wings role prints the value to use.
# Requires an A record mc.fordkuppp.me -> caddy_bind_ip (Cloudflare proxy OFF,
# it does not carry raw TCP) and 25565/tcp open in the provider firewall.
caddy_l4_routes: [] # TODO: set upstream once wings-1 has joined the tailnet
#   - listen_port: 25565
#     upstream: 100.x.y.z:25565
```

- [x] **Step 9: Verify the Caddyfile template renders valid syntax**

```bash
cd ansible && python3 -c "
import jinja2, pathlib
src = pathlib.Path('roles/caddy_gateway/templates/Caddyfile.j2').read_text()
print(jinja2.Template(src).render(
    ansible_managed='Ansible managed',
    caddy_email='a@b.com',
    caddy_bind_ip='117.18.125.45',
    caddy_sites=[{'host': 'x.example.com', 'upstream': '192.168.1.3:80'}],
    caddy_l4_routes=[{'listen_port': 25565, 'upstream': '100.64.0.5:25565'}],
))
"
```

Expected: a Caddyfile with a `layer4` block nested inside the global `{ }`, one `117.18.125.45:25565` listener, and the HTTP site below. Check by eye that the braces balance.

- [x] **Step 10: Verify the empty case still renders**

Re-run Step 9 with `caddy_l4_routes=[]`. Expected: output identical to the current Caddyfile — no `layer4` block at all. This is what guarantees the change is inert until a route is declared.

- [x] **Step 11: Syntax-check the playbook**

```bash
cd ansible && ansible-playbook --syntax-check playbooks/caddy-gateway.yaml
```

Expected: exit 0.

- [x] **Step 12: Commit**

```bash
git add ansible/roles/caddy_gateway/ inventory/group_vars/edge.yaml
git commit -m "Teach caddy_gateway raw TCP via caddy-l4

Minecraft is not HTTP, and the apt Caddy has no layer4 module. Build Caddy
with caddy-l4 on the controller (same pattern as derper) and point the unit
at it with a systemd drop-in, so an apt upgrade cannot restore a binary that
would drop every game connection.

The assert now accepts L4 routes with no HTTP sites, and the Caddyfile
validator is pinned to the custom binary -- the apt one rejects layer4.
Inert until caddy_l4_routes is non-empty."
```

---

### Task 8: The Panel app in Kubernetes

Red/green works literally here: list the resource in `kustomization.yaml` first, watch `kustomize build` fail, then create the file.

**Files:**
- Create: `kubernetes/apps/pelican/kustomization.yaml`
- Create: `kubernetes/apps/pelican/namespace.yaml`
- Create: `kubernetes/apps/pelican/pvc.yaml`
- Create: `kubernetes/apps/pelican/deployment.yaml`
- Create: `kubernetes/apps/pelican/httproute.yaml`

- [x] **Step 1: Write the kustomization listing files that do not exist yet**

`kubernetes/apps/pelican/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - pvc.yaml
  - deployment.yaml
  - httproute.yaml
  - wings-1.yaml
  - backup-cronjob.yaml
```

- [x] **Step 2: Run the build and watch it fail**

Run: `kustomize build kubernetes/apps/pelican/`
Expected: FAIL — `accumulating resources: accumulation err=... namespace.yaml: no such file or directory`.

- [x] **Step 3: The namespace**

`kubernetes/apps/pelican/namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: pelican
  labels:
    k8up-backup: enabled
```

- [x] **Step 4: The volume**

SQLite over NFS is a known corruption path, so this is `local-path`, not `nfs-csi`. The cluster is single-node, so node affinity costs nothing.

No `PersistentVolume` here: `local-path` is a dynamic provisioner, unlike the hand-written `nfs-csi` PVs elsewhere in this repo. The claim is the whole story.

`kubernetes/apps/pelican/pvc.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pelican-data-pvc
  namespace: pelican
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources:
    requests:
      storage: 5Gi
```

- [x] **Step 5: The Deployment and Service**

`kubernetes/apps/pelican/deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pelican
  namespace: pelican
  labels:
    app.kubernetes.io/name: pelican
spec:
  revisionHistoryLimit: 3
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app.kubernetes.io/name: pelican
  template:
    metadata:
      labels:
        app.kubernetes.io/name: pelican
    spec:
      enableServiceLinks: false
      containers:
        - name: pelican
          image: ghcr.io/pelican/panel:v1.0.0-rc.2
          env:
            - name: XDG_DATA_HOME
              value: /pelican-data
            - name: APP_URL
              value: https://panel.local.fordkuppp.me
            - name: APP_ENV
              value: production
            - name: APP_DEBUG
              value: "false"
            - name: APP_TIMEZONE
              value: Asia/Bangkok
            - name: TZ
              value: Asia/Bangkok
            - name: BEHIND_PROXY
              value: "true"
            # Envoy runs in-cluster, so the panel sees the proxy's POD address.
            - name: TRUSTED_PROXIES
              value: 10.42.0.0/16
            - name: ADMIN_EMAIL
              value: fordpatsakorn@gmail.com
          ports:
            - name: http
              containerPort: 80
              protocol: TCP
          # Before the install wizard runs, / is a 302 to /installer. Kubernetes
          # counts 200-399 as success, so this probe is correct in both states.
          livenessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 60
            periodSeconds: 30
          readinessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 20
            periodSeconds: 10
          volumeMounts:
            - name: data
              mountPath: /pelican-data
            - name: logs
              mountPath: /var/www/html/storage/logs
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: pelican-data-pvc
        - name: logs
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: pelican
  namespace: pelican
spec:
  selector:
    app.kubernetes.io/name: pelican
  ports:
    - name: http
      port: 80
      targetPort: http
```

- [x] **Step 6: The route**

`kubernetes/apps/pelican/httproute.yaml`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: pelican
  namespace: pelican
spec:
  parentRefs:
    - name: tailscale-gateway
      namespace: tailscale
  hostnames:
    - "panel.local.fordkuppp.me"
  rules:
    - backendRefs:
        - name: pelican
          port: 80
```

- [x] **Step 7: Build and validate**

The build still fails on `wings-1.yaml` and `backup-cronjob.yaml` (Tasks 9 and 10). Temporarily comment those two lines out of `kustomization.yaml`, then run:

```bash
kustomize build kubernetes/apps/pelican/ | kubeconform \
  -strict -ignore-missing-schemas -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  -summary
```

Expected: `Summary: 5 resources found ... 0 errors, 0 skipped` (or skipped for the HTTPRoute CRD).

Uncomment both lines again before committing — they are restored in Tasks 9 and 10.

- [x] **Step 8: Commit**

```bash
git add kubernetes/apps/pelican/
git commit -m "Add the Pelican Panel app

SQLite on a local-path PVC. The shared CNPG cluster runs PG16 and Pelican
needs 17+, and a major-version upgrade of a cluster immich, pocket-id and
actual all depend on is far too much blast radius for one new app.

local-path rather than nfs-csi because SQLite locking over NFS corrupts."
```

---

### Task 9: Route the Wings API through the gateway

**Files:**
- Create: `kubernetes/apps/pelican/wings-1.yaml`

- [x] **Step 1: Write it**

Lifted from `kubernetes/apps/external/proxmox.yaml`, which already solves "route to a non-cluster IP, with a console websocket that must not time out".

```yaml
# The browser talks to Wings directly for the console websocket and the file
# manager, so Wings needs a trusted cert. Rather than running certbot on every
# Wings VM, terminate at the gateway: the wildcard cert-manager certificate
# already covers wings-N.local.fordkuppp.me, so adding a node is this file again
# with a new address. Wings itself speaks plain HTTP (api.ssl.enabled: false).
apiVersion: v1
kind: Service
metadata:
  name: wings-1
  namespace: pelican
spec:
  ports:
    - name: http
      port: 8080
      targetPort: 8080
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: wings-1
  namespace: pelican
  labels:
    kubernetes.io/service-name: wings-1
addressType: IPv4
ports:
  - name: http
    port: 8080
endpoints:
  - addresses:
      - "192.168.1.30"
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: wings-1
  namespace: pelican
spec:
  parentRefs:
    - name: tailscale-gateway
      namespace: tailscale
  hostnames:
    - "wings-1.local.fordkuppp.me"
  rules:
    - backendRefs:
        - name: wings-1
          port: 8080
---
# The server console is a long-lived websocket, same as the PVE console.
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: wings-1
  namespace: pelican
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: wings-1
  timeout:
    http:
      requestTimeout: "0s"
```

- [x] **Step 2: Build and validate**

Restore the `wings-1.yaml` line in `kustomization.yaml` if it is still commented, then run the Step 7 command from Task 8 (with `backup-cronjob.yaml` still commented out).

Expected: `9 resources found`, 0 errors.

- [x] **Step 3: Commit**

```bash
git add kubernetes/apps/pelican/
git commit -m "Route the Wings API through the Envoy gateway

Reuses the external/proxmox.yaml pattern: selector-less Service +
EndpointSlice at the VM, plus the zero request timeout the console
websocket needs."
```

---

### Task 10: Consistent SQLite snapshots before the backup window

restic snapshots a live SQLite file, which can tear if a write lands mid-copy. A nightly consistent copy gives k8up something guaranteed-restorable to pick up.

**Files:**
- Create: `kubernetes/apps/pelican/backup-cronjob.yaml`

- [x] **Step 1: Write it**

Runs at 02:55, twenty minutes before the k8up schedule in Task 12. Mounts the same RWO PVC as the Panel — fine, both land on the single node.

Two choices worth knowing before you read the YAML:

- **It runs the Panel's own image, not `alpine` + `apk add sqlite`.** The Panel image ships no `sqlite3` CLI, but its PHP has the `sqlite3` extension (verified: SQLite 3.53.4). Reusing the image means one fewer tag to track, no network fetch inside the job, and a uid that already matches the writer. `VACUUM INTO` is the same mechanism behind the `.backup` dot-command.
- **`enableExceptions(true)` is load-bearing.** `SQLite3::exec()` defaults to emitting a warning and returning `false`, so without it a failed backup exits 0 and the CronJob reports success over a stale snapshot. Verified both ways.

```yaml
# k8up/restic copies the SQLite file byte-for-byte, which tears if a write
# lands mid-copy. VACUUM INTO takes a consistent copy twenty minutes ahead of
# the k8up schedule, so the restic snapshot always contains one database that
# is known to be restorable.
#
# Running the panel's own image avoids a second image to track and guarantees
# the uid and the SQLite build match the writer. It ships no sqlite3 CLI, but
# its PHP has the sqlite3 extension, and VACUUM INTO is the same mechanism the
# `.backup` dot-command uses.
apiVersion: batch/v1
kind: CronJob
metadata:
  name: pelican-sqlite-snapshot
  namespace: pelican
spec:
  schedule: "55 2 * * *"
  timeZone: Asia/Bangkok
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          enableServiceLinks: false
          securityContext:
            runAsUser: 82
            runAsGroup: 82
            fsGroup: 82
          containers:
            - name: snapshot
              image: ghcr.io/pelican/panel:v1.0.0-rc.2
              command:
                - php
                - -r
                - |
                  $src = '/pelican-data/database/database.sqlite';
                  $dst = '/pelican-data/snapshots/panel.sqlite';
                  if (!is_file($src)) {
                      fwrite(STDERR, "no database at {$src} yet -- the panel installer has not run\n");
                      exit(0);
                  }
                  if (!is_dir(dirname($dst)) && !mkdir(dirname($dst), 0750, true)) {
                      fwrite(STDERR, "cannot create " . dirname($dst) . "\n");
                      exit(1);
                  }
                  $tmp = $dst . '.tmp';
                  @unlink($tmp);
                  $db = new SQLite3($src, SQLITE3_OPEN_READONLY);
                  // Without this, a failed VACUUM is a warning and the job still exits 0.
                  $db->enableExceptions(true);
                  $db->exec("VACUUM INTO '{$tmp}'");
                  $db->close();
                  if (!rename($tmp, $dst)) {
                      fwrite(STDERR, "cannot move {$tmp} into place\n");
                      exit(1);
                  }
                  fwrite(STDERR, "snapshot written to {$dst}\n");
              volumeMounts:
                - name: data
                  mountPath: /pelican-data
          volumes:
            - name: data
              persistentVolumeClaim:
                claimName: pelican-data-pvc
```

- [x] **Step 2: Build and validate the whole app**

All files now exist. Restore both commented lines in `kustomization.yaml` and run:

```bash
kustomize build kubernetes/apps/pelican/ | kubeconform \
  -strict -ignore-missing-schemas -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  -summary
```

Expected: `10 resources found`, 0 errors.

- [x] **Step 3: Commit**

```bash
git add kubernetes/apps/pelican/
git commit -m "Snapshot the panel SQLite before the backup window

restic copying a live SQLite file can tear. VACUUM INTO makes a
consistent copy twenty minutes ahead of the k8up schedule."
```

The path is confirmed, not assumed: in the image,
`/var/www/html/database/database.sqlite` is a symlink to
`/pelican-data/database/database.sqlite`.

---

### Task 11: Flux Kustomization

**Files:**
- Create: `kubernetes/flux/pelican.yaml`
- Modify: `kubernetes/flux/kustomization.yaml`

- [x] **Step 1: Write the Kustomization**

No Postgres dependency — this app uses SQLite.

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: pelican
  namespace: flux-system
spec:
  interval: 10m0s
  path: kubernetes/apps/pelican
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  wait: true
  dependsOn:
    - name: systems
```

- [x] **Step 2: Register it**

Add `- pelican.yaml` to the `resources` list in `kubernetes/flux/kustomization.yaml`, keeping the existing ordering convention of that file.

- [x] **Step 3: Validate**

```bash
kustomize build kubernetes/flux/ | kubeconform \
  -strict -ignore-missing-schemas -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  -summary
```

Expected: 0 errors, and the resource count is one higher than before.

- [x] **Step 4: Commit**

```bash
git add kubernetes/flux/
git commit -m "Wire the pelican app into Flux"
```

---

### Task 12: k8up schedule for the Panel

**Files:**
- Create: `kubernetes/apps/k8up-schedules/pelican.yaml`
- Modify: `kubernetes/apps/k8up-schedules/kustomization.yaml`

- [x] **Step 1: Write the schedule**

A copy of `pocket-id.yaml` with the bucket and times changed. Every existing schedule time is listed by `grep -n 'schedule:' kubernetes/apps/k8up-schedules/*.yaml`; these three slots are the free ones nearest the CronJob in Task 10. Note the check is **not** `15 5 * * 0` — `metrics-exporter` already holds it.

```yaml
apiVersion: k8up.io/v1
kind: Schedule
metadata:
  name: pelican
  namespace: pelican
spec:
  backend:
    repoPasswordSecretRef:
      name: k8up-repo
      key: password
    s3:
      bucket: homelab-backups/pelican
      accessKeyIDSecretRef:
        name: k8up-repo
        key: access_key
      secretAccessKeySecretRef:
        name: k8up-repo
        key: secret_key
  backup:
    # Twenty minutes after the pelican-sqlite-snapshot CronJob, so every
    # restic snapshot contains a consistent copy of the database.
    schedule: "15 3 * * *"
    failedJobsHistoryLimit: 3
    successfulJobsHistoryLimit: 1
  check:
    schedule: "30 6 * * 0"
  prune:
    schedule: "55 3 * * *"
    retention:
      keepDaily: 14
      keepWeekly: 8
      keepMonthly: 6
```

- [x] **Step 2: Register it**

Add `- pelican.yaml` to the `resources` list in `kubernetes/apps/k8up-schedules/kustomization.yaml`.

- [x] **Step 3: Validate**

```bash
kustomize build kubernetes/apps/k8up-schedules/ | kubeconform \
  -strict -ignore-missing-schemas -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  -summary
```

Expected: 0 errors.

- [x] **Step 4: Commit**

```bash
git add kubernetes/apps/k8up-schedules/
git commit -m "Back up the pelican panel volume"
```

---

### Task 13: Renovate

Three new pins live in Ansible files, which no built-in manager reads. Pelican is on `v1.0.0-rc.2`, and Renovate skips prereleases by default — without `ignoreUnstable: false` it would never offer a bump.

**Files:**
- Modify: `renovate.json`

- [x] **Step 1: Add the custom managers**

Append these three objects to the `customManagers` array, after the existing derper entry:

```json
    {
      "customType": "regex",
      "description": "Pelican Wings: the daemon binary installed on the games group",
      "managerFilePatterns": [
        "/^ansible/roles/pelican_wings/defaults/main\\.yaml$/",
        "/^inventory/group_vars/games\\.yaml$/"
      ],
      "matchStrings": [
        "pelican_wings_version:\\s*\"?(?<currentValue>v[0-9][^\"\\s#]*)\"?"
      ],
      "depNameTemplate": "pelican/wings",
      "datasourceTemplate": "github-releases"
    },
    {
      "customType": "regex",
      "description": "Caddy: rebuilt from source with caddy-l4, so the version is pinned here rather than apt",
      "managerFilePatterns": [
        "/^ansible/roles/caddy_gateway/defaults/main\\.yaml$/",
        "/^inventory/group_vars/edge\\.yaml$/"
      ],
      "matchStrings": [
        "caddy_version:\\s*\"?(?<currentValue>v[0-9][^\"\\s#]*)\"?"
      ],
      "depNameTemplate": "caddyserver/caddy",
      "datasourceTemplate": "github-releases"
    },
    {
      "customType": "regex",
      "description": "caddy-l4: the layer4 module compiled into the custom Caddy build",
      "managerFilePatterns": [
        "/^ansible/roles/caddy_gateway/defaults/main\\.yaml$/",
        "/^inventory/group_vars/edge\\.yaml$/"
      ],
      "matchStrings": [
        "caddy_l4_version:\\s*\"?(?<currentValue>v[0-9][^\"\\s#]*)\"?"
      ],
      "depNameTemplate": "mholt/caddy-l4",
      "datasourceTemplate": "github-releases"
    }
```

- [x] **Step 2: Add the package rule**

Append to the `packageRules` array:

```json
    {
      "description": "Pelican is pre-1.0 and ships release candidates. Renovate skips prereleases by default, so without ignoreUnstable it would never propose a bump at all. Breaking changes between RCs are realistic -- always a human and a changelog read.",
      "matchPackageNames": [
        "pelican/**",
        "ghcr.io/pelican/**"
      ],
      "ignoreUnstable": false,
      "automerge": false
    }
```

- [x] **Step 3: Validate the JSON**

```bash
python3 -c "import json; json.load(open('renovate.json')); print('valid')"
```

Expected: `valid`.

- [x] **Step 4: Check the regexes match the real files**

```bash
grep -nE 'pelican_wings_version:|caddy_version:|caddy_l4_version:' \
  ansible/roles/pelican_wings/defaults/main.yaml \
  ansible/roles/caddy_gateway/defaults/main.yaml
```

Expected: three lines, each with a `v`-prefixed quoted version. If a pin is unquoted or lacks the `v`, the manager will not match it.

- [x] **Step 5: Commit**

```bash
git add renovate.json
git commit -m "Track wings, caddy and caddy-l4 in Renovate

Pelican is on v1.0.0-rc.2; ignoreUnstable: false or Renovate never offers
a bump on a prerelease tag. Never automerged."
```

---

### Task 14: Documentation

**Files:**
- Modify: `docs/ip-plan.md`
- Modify: `ansible/README.md`
- Create: `docs/runbooks/pelican.md`

- [x] **Step 1: Update the IP plan**

In `docs/ip-plan.md`, replace:

```markdown
### Komodo docker
- `192.168.1.30–192.168.1.39`
```

with:

```markdown
### Game servers
- `192.168.1.30–192.168.1.39`
- `192.168.1.30` — wings-1 (Pelican Wings)

> Formerly the Komodo docker range. Komodo is retired; `docker-1` held `.30`
> and was decommissioned when wings-1 took the address.
```

- [x] **Step 2: Document the new roles**

Append two sections to `ansible/README.md`, matching the existing style (what it does, why, how to run it, what to do afterwards, and a Scope note).

The "Provision the whole Wings VM" section:

````markdown
## Provision the whole Wings VM

`composite/wings.yaml` runs baseline hardening, then tailscaled, then Wings on
the `games` group:

```fish
cd ansible
ansible-playbook playbooks/composite/wings.yaml \
  -e "tailscale_authkey=$(bws secret get $BWS_TS_GAMES_AUTHKEY_ID | jq -r .value)" \
  -e "pelican_node_uuid=$(bws secret get $BWS_PELICAN_NODE_UUID_ID | jq -r .value)" \
  -e "pelican_node_token_id=$(bws secret get $BWS_PELICAN_NODE_TOKEN_ID_ID | jq -r .value)" \
  -e "pelican_node_token=$(bws secret get $BWS_PELICAN_NODE_TOKEN_ID | jq -r .value)"
```

The node credentials come from the Panel and must exist first — see
[`docs/runbooks/pelican.md`](../docs/runbooks/pelican.md).
````

The "pelican-wings" section should cover: Wings runs plain HTTP because the
Envoy gateway terminates TLS; `trusted_proxies` is the k3s node address, not
the pod CIDR, because flannel masquerades pod egress; backups mount the TrueNAS
`general/backup` dataset, which is already snapshotted daily; and `accept-routes`
is off because the box is already on the LAN. Scope: Wings only — it does not
create the Node in the Panel or open any firewall.

Also update the **tailscale-derp** section to note that the tailscaled install
now comes from the `tailscale_node` role.

- [x] **Step 3: Write the runbook**

`docs/runbooks/pelican.md` covers the steps that have no API. Write it to
contain, in order:

1. **Prerequisite** — `docker-1` decommissioned, `.30` free.
2. **Tailnet** — add `tag:games` to `tagOwners` in the tailnet policy; create a
   tagged pre-auth key; store as `BWS_TS_GAMES_AUTHKEY_ID`.
3. **VM** — `terragrunt apply --working-dir terragrunt/proxmox/vm/wings-1`.
4. **Panel** — merge to `main`, wait for Flux, confirm
   `https://panel.local.fordkuppp.me` loads.
5. **Install wizard** — the first visit serves `/installer`; it creates the
   admin user and writes config into `/pelican-data`. Keep the SQLite default.
6. **Create the Node** — Admin → Nodes → Create. FQDN
   `wings-1.local.fordkuppp.me`, port `8080`, **SSL on** (the gateway presents
   it), daemon SFTP port `2022`. Copy the generated `uuid`, `token_id` and
   `token` into Bitwarden.
7. **Prove the snapshot job** — now that a database exists, don't wait for
   02:55: `kubectl -n pelican create job --from=cronjob/pelican-sqlite-snapshot
   snapshot-test`, then check `kubectl -n pelican logs job/snapshot-test` says
   `snapshot written`. Delete the job afterwards.
8. **Run the composite play** (command as in `ansible/README.md`).
9. **Verify the node** — it should show green in the Panel.
10. **Create the Minecraft server** — pick a Fabric or Forge egg, allocate
    `192.168.1.30:25565`, and start it. Verify from the LAN first.
11. **Public exposure** — set `caddy_l4_routes` in
    `inventory/group_vars/edge.yaml` to the tailnet IP the Wings play printed;
    run `ansible-playbook playbooks/caddy-gateway.yaml`; create the
    `mc.fordkuppp.me` A record to `117.18.125.45` with the Cloudflare proxy
    **off**; open `25565/tcp` on that IP in the ReadyIDC security group.
12. **Verify end to end** — the table in the spec's Verification section.

Include this warning: all players will share one source IP, because Fabric and
Forge cannot read PROXY protocol. Ban by UUID, not IP.

- [x] **Step 4: Commit**

```bash
git add docs/ ansible/README.md
git commit -m "Document the Pelican setup

Renames the .30-.39 range to Game servers, and adds the runbook for the
steps that have no API: the install wizard and node registration."
```

---

### Task 15: Human runbook — apply and verify

Not a code task. Follow `docs/runbooks/pelican.md` in order, after merging this branch to `main` (the `FluxInstance` syncs `refs/heads/main`, so nothing deploys before that).

Verify in this order; each gates the next:

- [ ] `terragrunt hcl validate` passes for `docker-1`, `k3s-1` and `wings-1`
- [ ] **Re-run `playbooks/composite/edge.yaml` against `derp-bkk-01` and confirm the `tailscale_node` extraction changed nothing** — `--check --diff` first. Do this before anything else depends on the new role.
- [ ] `tailscale netcheck` from any client still lists the `bkk` region
- [ ] `ansible games -m ping` succeeds
- [ ] `tailscale ping wings-1` from the VPS reports **direct**, not `via DERP`
- [ ] `systemctl status wings` on the VM is active
- [ ] `curl -I https://wings-1.local.fordkuppp.me` returns a Wings response with a valid cert
- [ ] **The Panel shows the node green** — this exercises the hairpin in spec risk R2 and is the single most likely thing to break. If it fails, fall back to giving Wings its own DNS-01 cert and dropping the gateway route.
- [ ] A server console opens, streams, and does not time out
- [ ] `/usr/local/bin/caddy list-modules | grep layer4` on the VPS lists the module
- [ ] Connecting to `mc.fordkuppp.me` from off-net (mobile data) works
- [ ] A Wings backup appears under `/mnt/general/backup` on TrueNAS
- [ ] A k8up snapshot lands in `homelab-backups/pelican`
