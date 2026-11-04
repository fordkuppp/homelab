# Static Caddyfile for the edge gateway — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Jinja-templated Caddyfile and its inventory variables with one hand-written Caddyfile, so adding a Minecraft server or a public HTTP app is a one-line edit in plain Caddyfile syntax.

**Architecture:** The `caddy_gateway` role copies `files/Caddyfile` verbatim, validates it with the caddy-l4 build, and reloads Caddy. Per-server Caddyfile syntax is written once as a Caddyfile snippet with arguments (`(mc_server)`), so each game server is `import mc_server <label> <upstream>`. A fixed 28-byte matcher anchored on the hostname-length byte replaces the per-hostname byte count the template used to compute. A loopback test script proves the routing rule without a Minecraft client.

**Tech Stack:** Ansible, Caddy 2.11 + caddy-l4 0.1.2 (Caddyfile snippets, `import` with args, `layer4` regexp matcher), Python 3 stdlib for the test.

**Why:** Reading a Caddyfile is one skill. Reading a Jinja template that emits a Caddyfile is a second skill stacked on the first, and the template's only real computation (a byte count per hostname) turns out to be avoidable. Design discussion: this plan's parent session, 2026-11-04.

---

## Before you start

**1. The working tree has uncommitted work from another effort (Send public share + Anubis, spec `docs/superpowers/specs/2026-11-04-send-public-share-design.md`).** This plan edits those files *as they stand in the working tree*, not as of `HEAD`. Do not start until `git status` is clean, i.e. that work is committed. If it has been reverted instead, the Anubis snippet and the `share.app.fordkuppp.me` site in Task 1 must be dropped and Task 4 shrinks accordingly — ask before guessing.

**2. You need the caddy-l4 build on the controller.** Every validation step below uses it. Check:

```fish
ls -la /tmp/caddy-v2.11.7-l4-v0.1.2
```

If it is missing, build it the way the role does (needs Go):

```fish
go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
GOOS=linux GOARCH=amd64 (go env GOPATH)/bin/xcaddy build v2.11.7 --with github.com/mholt/caddy-l4@v0.1.2 --output /tmp/caddy-v2.11.7-l4-v0.1.2
```

**3. How to verify in this repo.** There is no unit-test framework. The red/green loop here is: a validator that rejects the tree, then accepts it.

| Layer | Command (from repo root unless noted) |
|---|---|
| Caddyfile parses | `/tmp/caddy-v2.11.7-l4-v0.1.2 adapt --config ansible/roles/caddy_gateway/files/Caddyfile --adapter caddyfile` |
| Caddyfile routes correctly | `python3 ansible/roles/caddy_gateway/tests/mc_routing.py /tmp/caddy-v2.11.7-l4-v0.1.2` (Task 2 creates it) |
| Ansible syntax | `cd ansible && ansible-playbook --syntax-check playbooks/caddy-gateway.yaml` |
| Ansible dry run | `cd ansible && ansible-playbook --check --diff playbooks/caddy-gateway.yaml` |
| Live | Task 7 |

## Facts the design rests on (measured, not assumed)

These were established against the real caddy-l4 0.1.2 build on 2026-11-04 with hand-built handshake packets. Task 2's script re-proves them.

- **caddy-l4's `regexp` matcher reads exactly `count` bytes** (`io.ReadFull`) and reports no-match if fewer arrive. So `count` must be ≤ what every client sends before it waits for a reply. A status ping sends `len(hostname) + 10` bytes. For any `<label>.games.fordkuppp.me` that is ≥ 30, so **28 is safe for every hostname** under the wildcard. The previous template needed a per-hostname count only because it matched the whole hostname.
- **The matcher runs the pattern through Caddy's placeholder replacer before compiling it** (`repl.ReplaceAll(m.Pattern, "")` in `l4regexp/matcher.go`). Anything in `{braces}` is stripped. `.{4,6}` silently becomes `.`. **Never use a brace quantifier in these patterns.**
- **Anchoring on the hostname-length byte works for every protocol-varint width.** The byte before the hostname is its length. For any label that fits in 28 bytes that byte is 20..36, never a hostname character, so `[^a-z0-9.-]<label>\.games` matches only at the real label start: `mc` does not match `xmc`, `val` does not match `survival`. Verified with 1-, 2-, 3- and 5-byte (snapshot) protocol varints.
- **Labels up to 17 characters fit.** With the current 5-byte header, `5 + len(label) + len(".games")` must be ≤ 28. An 18-char label silently falls through to the fallback. The Caddyfile comment says so.
- **The fallback route needs an always-true 1-byte matcher**, not no matcher. Unchanged from commit `4139f55`; a 2-byte legacy ping reaches it in ~1 ms.

## What this plan does NOT do

- Touch the custom-build tasks (xcaddy, binary shipping, systemd drop-in). They stay as they are.
- Change the Anubis role beyond two variable names it shared with the Caddy role.
- Edit the dated specs and plans under `docs/superpowers/` that mention `caddy_minecraft_servers`. They are historical records.
- Add a second game protocol or a second edge host.

## File map

| File | Change | Responsibility after this plan |
|---|---|---|
| `ansible/roles/caddy_gateway/files/Caddyfile` | **create** | The gateway config. Hand-edited. The only place sites and game servers are listed. |
| `ansible/roles/caddy_gateway/templates/Caddyfile.j2` | **delete** | — |
| `ansible/roles/caddy_gateway/tests/mc_routing.py` | **create** | Loopback proof that the `(mc_server)` snippet routes by label. |
| `ansible/roles/caddy_gateway/defaults/main.yaml` | rewrite | Build pins only. |
| `ansible/roles/caddy_gateway/tasks/main.yaml` | edit | Drop the three asserts and the next-steps message; `template` → `copy`. |
| `ansible/playbooks/caddy-gateway.yaml` | edit | Drop the `when:` guard. |
| `ansible/playbooks/composite/edge.yaml` | edit | Comment. |
| `ansible/playbooks/anubis.yaml` | edit | `caddy_anubis_enabled` → `anubis_enabled`. |
| `ansible/roles/anubis/defaults/main.yaml` | edit | `anubis_enabled`, `anubis_redirect_domains: []`. |
| `ansible/inventory/group_vars/edge.yaml` | rewrite the Caddy half | No site/server lists; points at the Caddyfile. |
| `ansible/roles/pelican_wings/tasks/main.yaml` | edit | Next-steps message names the Caddyfile line to add. |
| `ansible/README.md`, `docs/runbooks/pelican.md`, `docs/runbooks/send.md`, `docs/ip-plan.md`, `kubernetes/apps/dns/records.yaml` | edit | Prose that said "add an inventory entry" now says "add a Caddyfile line". |

---

### Task 1: The hand-written Caddyfile

**Files:**
- Create: `ansible/roles/caddy_gateway/files/Caddyfile`

- [ ] **Step 1: Confirm the adapt check fails on a missing file (red)**

Run from the repo root:

```fish
/tmp/caddy-v2.11.7-l4-v0.1.2 adapt --config ansible/roles/caddy_gateway/files/Caddyfile --adapter caddyfile
```

Expected: an error mentioning `no such file or directory`.

- [ ] **Step 2: Write the Caddyfile**

Create `ansible/roles/caddy_gateway/files/Caddyfile` with exactly this content. Tabs for indentation (Caddy's formatter uses tabs; `caddy fmt` will otherwise rewrite the file).

```caddyfile
# Public gateway on the edge VPS's second IP. Hand-written -- there is no
# template. Ansible copies this file as-is, validates it with the caddy-l4
# build, and reloads Caddy.
#
# Add a Minecraft server: one `import mc_server <label> <upstream>` line in the
# 25565 listener. The *.games.fordkuppp.me wildcard already resolves
# <label>.games.fordkuppp.me and 25565 is already open, so nothing else moves.
#
# Add a public HTTP app: one site block at the bottom, same shape as
# share.app.fordkuppp.me, plus its hostname in anubis_redirect_domains
# (inventory/group_vars/edge.yaml). The *.app.fordkuppp.me wildcard already
# resolves it.

# One Minecraft server: send the label the player typed to an upstream.
# Minecraft has no Host header or SNI, but the client copies the typed
# address into its handshake packet as plain text, so the matcher reads it off
# the first bytes of the connection.
#
# The matcher reads exactly 28 bytes and reports no-match if fewer arrive. A
# status ping sends only len(hostname)+10 bytes, which is >= 30 for any name
# under the wildcard, so 28 never makes a ping hang. It leaves room for
# labels up to 17 characters; a longer label silently hits the fallback.
#
# [^a-z0-9.-] pins the label to the byte before it, the hostname-length
# field. For any label that fits in 28 bytes that byte is 20..36, never a
# hostname character, so `mc` cannot match `xmc` and the anchor holds for
# every protocol-varint width. A brace quantifier such as .{4,6} would NOT
# work here: caddy-l4 runs the pattern through Caddy's placeholder replacer,
# which strips anything in braces.
(mc_server) {
	@{args[0]} regexp (?i)[^a-z0-9.-]{args[0]}\.games 28
	route @{args[0]} {
		proxy {args[1]}
	}
}

# Anubis in subrequest mode. forward_auth asks it for a verdict on every
# request; a 401 means "challenge first", so the client is bounced to the
# challenge page, which Caddy serves from this same host by proxying the
# /.within.website/ prefix to Anubis. Anubis never sees the upstream -- that
# stays Caddy's job -- so one instance covers every site. 127.0.0.1:8923 is
# anubis_bind in the anubis role.
(anubis) {
	route {
		reverse_proxy /.within.website/* 127.0.0.1:8923
		forward_auth 127.0.0.1:8923 {
			uri /.within.website/x/cmd/anubis/api/check
			trusted_proxies private_ranges
			@unauthorized status 401
			handle_response @unauthorized {
				redir * /.within.website/?redir={uri} 307
			}
		}
	}
}

{
	email fordpatsakorn@gmail.com
	# Every listener (incl. the :80 ACME/redirect vhost) stays on the second
	# public IP so Caddy never touches derper's :443 on the first one.
	default_bind 117.18.125.45

	# Raw TCP. default_bind does NOT apply to layer4 listeners, so the IP is
	# explicit here -- otherwise this would listen on 0.0.0.0 and spill onto
	# derper's IP.
	layer4 {
		# Every Minecraft server shares this listener and is told apart by the
		# label the player typed. Upstreams are wings-1's TAILNET address, not
		# its LAN address: the VPS reaches it peer-to-peer, keeping the
		# cluster's subnet router out of the player data path.
		117.18.125.45:25565 {
			import mc_server mc 100.68.244.45:25565

			# Matched nothing above: a raw-IP connect or an unknown name. The
			# always-true 1-byte matcher is deliberate. A matcher-less route is
			# reached only once every matcher above has returned a verdict,
			# and one still waiting on bytes that never arrive (a 2-byte
			# legacy ping) never does -- the connection would hang for
			# matching_timeout and drop. To hide the server from port scanners
			# instead, replace the proxy line with `close` (then the path can
			# no longer be tested by IP).
			@any regexp (?s). 1
			route @any {
				proxy 100.68.244.45:25565
			}
		}
	}
}

# Public HTTP apps. Those in the cluster sit behind the Envoy gateway, which
# terminates TLS for *.app.fordkuppp.me itself, so Caddy re-encrypts to the
# gateway's LAN VIP with the site's hostname as SNI and checks the certificate
# against it. The upstream is an IP, so the SNI has to be given explicitly.
share.app.fordkuppp.me {
	import anubis
	reverse_proxy https://192.168.1.3:443 {
		transport http {
			tls_server_name share.app.fordkuppp.me
		}
	}
}
```

- [ ] **Step 3: Adapt it (green)**

```fish
/tmp/caddy-v2.11.7-l4-v0.1.2 adapt --config ansible/roles/caddy_gateway/files/Caddyfile --adapter caddyfile | python3 -c 'import sys,json; d=json.load(sys.stdin); r=d["apps"]["layer4"]["servers"]["srv0"]; print(r["listen"]); print([x["match"][0]["regexp"] for x in r["routes"]]); print(list(d["apps"]["http"]["servers"]))'
```

Expected output, exactly:

```
['117.18.125.45:25565']
[{'count': 28, 'pattern': '(?i)[^a-z0-9.-]mc\\.games'}, {'count': 1, 'pattern': '(?s).'}]
['srv0']
```

If the first pattern shows `mc\\.games` with no `[^a-z0-9.-]` in front, or any brace quantifier survived, stop: the snippet args did not substitute as intended.

- [ ] **Step 4: Check the formatter agrees**

```fish
/tmp/caddy-v2.11.7-l4-v0.1.2 fmt ansible/roles/caddy_gateway/files/Caddyfile | diff ansible/roles/caddy_gateway/files/Caddyfile -
```

Expected: no output (the formatter's output is byte-identical to the file). If it prints a diff, apply it with `fmt --overwrite` and re-run Step 3.

- [ ] **Step 5: Commit**

```bash
git add ansible/roles/caddy_gateway/files/Caddyfile
git commit -m "Write the gateway Caddyfile by hand

Caddyfile snippets with arguments give one import line per Minecraft
server, which is what the Jinja template was for. The per-hostname byte
count goes away: the matcher pins the label to the hostname-length byte
and reads a fixed 28 bytes, which is below the shortest status ping for
any name under *.games.fordkuppp.me.

Not yet wired in; the role still renders the template.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Loopback routing test

**Files:**
- Create: `ansible/roles/caddy_gateway/tests/mc_routing.py`

The script lifts the `(mc_server)` snippet out of the real Caddyfile (so it tests what ships), runs the caddy-l4 build on 127.0.0.1 with five labelled upstreams plus a fallback, and sends hand-built handshake packets. Each upstream answers with its own label, so the client learns where it landed.

- [ ] **Step 1: Write the script**

Create `ansible/roles/caddy_gateway/tests/mc_routing.py`:

```python
#!/usr/bin/env python3
"""Prove the (mc_server) snippet routes Minecraft handshakes by hostname label.

Lifts the snippet from the real Caddyfile, runs the caddy-l4 build on loopback
with labelled upstreams plus a fallback, and fires hand-built handshake packets
at the listener. Needs no network and no Minecraft client.

    python3 ansible/roles/caddy_gateway/tests/mc_routing.py /tmp/caddy-v2.11.7-l4-v0.1.2
"""
import re
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

CADDYFILE = Path(__file__).resolve().parents[1] / "files" / "Caddyfile"
LISTEN = 25565
FALLBACK = ("fallback", 25570)
# `val` is listed before `survival` on purpose: the anchor must stop the
# shorter label from matching inside the longer one.
UPSTREAMS = [
    ("val", 25569),
    ("mc", 25566),
    ("survival", 25567),
    ("a", 25568),
    ("abcdefghijklmnopq", 25571),  # 17 chars: the longest label that fits
]

CURRENT_PROTOCOL = 772
SNAPSHOT_PROTOCOL = 0x40000000 | 200  # snapshots set the high bit: a 5-byte varint


def varint(n):
    out = b""
    while True:
        byte = n & 0x7F
        n >>= 7
        out += bytes([byte | (0x80 if n else 0)])
        if not n:
            return out


def status_ping(hostname, protocol=CURRENT_PROTOCOL):
    """Handshake (next state = status) followed by the status request."""
    body = (
        b"\x00"
        + varint(protocol)
        + varint(len(hostname))
        + hostname.encode()
        + (25565).to_bytes(2, "big")
        + b"\x01"
    )
    return varint(len(body)) + body + b"\x01\x00"


CASES = [
    ("typed hostname", status_ping("mc.games.fordkuppp.me"), "mc"),
    ("upper-case hostname", status_ping("MC.GAMES.FORDKUPPP.ME"), "mc"),
    ("label that ends in another label", status_ping("survival.games.fordkuppp.me"), "survival"),
    ("the shorter of those two", status_ping("val.games.fordkuppp.me"), "val"),
    ("one-char label, the shortest ping", status_ping("a.games.fordkuppp.me"), "a"),
    ("17-char label, the longest that fits", status_ping("abcdefghijklmnopq.games.fordkuppp.me"), "abcdefghijklmnopq"),
    ("18-char label falls through", status_ping("abcdefghijklmnopqr.games.fordkuppp.me"), "fallback"),
    ("unknown label", status_ping("nope.games.fordkuppp.me"), "fallback"),
    ("label with a stray leading char", status_ping("xmc.games.fordkuppp.me"), "fallback"),
    ("1-byte protocol varint (1.8 client)", status_ping("mc.games.fordkuppp.me", 47), "mc"),
    ("3-byte protocol varint", status_ping("mc.games.fordkuppp.me", 20000), "mc"),
    ("5-byte snapshot protocol varint", status_ping("mc.games.fordkuppp.me", SNAPSHOT_PROTOCOL), "mc"),
    ("legacy FE 01 ping", b"\xfe\x01", "fallback"),
    ("single byte", b"\x00", "fallback"),
]


def mc_server_snippet():
    match = re.search(r"^\(mc_server\) \{\n.*?^\}\n", CADDYFILE.read_text(), re.S | re.M)
    if not match:
        sys.exit(f"no (mc_server) snippet found in {CADDYFILE}")
    return match.group(0)


def test_caddyfile():
    lines = [mc_server_snippet(), "{", "\tadmin off", "\tlayer4 {", f"\t\t127.0.0.1:{LISTEN} {{"]
    lines += [f"\t\t\timport mc_server {label} 127.0.0.1:{port}" for label, port in UPSTREAMS]
    lines += [
        "\t\t\t@any regexp (?s). 1",
        "\t\t\troute @any {",
        f"\t\t\t\tproxy 127.0.0.1:{FALLBACK[1]}",
        "\t\t\t}",
        "\t\t}",
        "\t}",
        "}",
    ]
    return "\n".join(lines) + "\n"


def serve_label(label, port):
    """Answer every connection with the label, so the client learns where it landed."""
    server = socket.socket()
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", port))
    server.listen(8)
    while True:
        conn, _ = server.accept()
        conn.settimeout(0.5)
        try:
            conn.recv(4096)
        except OSError:
            pass
        conn.sendall(label.encode())
        conn.close()


def wait_for_listener(port, timeout=5.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            socket.create_connection(("127.0.0.1", port), timeout=0.2).close()
            return
        except OSError:
            time.sleep(0.1)
    sys.exit(f"caddy never opened 127.0.0.1:{port}")


def probe(payload):
    started = time.time()
    conn = socket.create_connection(("127.0.0.1", LISTEN))
    conn.settimeout(4)
    conn.sendall(payload)
    try:
        landed = conn.recv(64).decode()
    except OSError:
        landed = "TIMEOUT"
    conn.close()
    return landed, (time.time() - started) * 1000


def main(caddy_bin):
    for label, port in UPSTREAMS + [FALLBACK]:
        threading.Thread(target=serve_label, args=(label, port), daemon=True).start()

    with tempfile.TemporaryDirectory() as tmp:
        config = Path(tmp) / "Caddyfile"
        config.write_text(test_caddyfile())
        caddy = subprocess.Popen(
            [caddy_bin, "run", "--config", str(config), "--adapter", "caddyfile"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        try:
            wait_for_listener(LISTEN)
            failures = 0
            for name, payload, want in CASES:
                landed, ms = probe(payload)
                ok = landed == want
                failures += not ok
                print(f"{'ok ' if ok else 'BAD'} {name:40s} -> {landed:18s} want {want:18s} {ms:5.0f} ms  {len(payload):3d} B")
        finally:
            caddy.terminate()
            caddy.wait()

    if failures:
        sys.exit(f"{failures} case(s) failed")
    print(f"all {len(CASES)} cases routed as expected")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
```

- [ ] **Step 2: Run it against the real Caddyfile (green)**

```fish
python3 ansible/roles/caddy_gateway/tests/mc_routing.py /tmp/caddy-v2.11.7-l4-v0.1.2
```

Expected: 14 lines starting `ok `, then `all 14 cases routed as expected`, exit 0. Every probe should be under ~50 ms; a 3000 ms line means a matcher hung for `matching_timeout`, which is the bug the 1-byte fallback matcher exists to prevent.

- [ ] **Step 3: Prove the test catches a wrong pattern (red)**

Temporarily break the anchor in `files/Caddyfile`: change `[^a-z0-9.-]{args[0]}\.games` to `{args[0]}\.games`. Re-run Step 2. Expected: `BAD label with a stray leading char -> mc` and `BAD label that ends in another label -> val`, exit 1. Then revert the change (`git checkout ansible/roles/caddy_gateway/files/Caddyfile`) and re-run Step 2 to confirm green again.

- [ ] **Step 4: Commit**

```bash
git add ansible/roles/caddy_gateway/tests/mc_routing.py
git commit -m "Prove the Minecraft label matcher on loopback

Runs the caddy-l4 build against hand-built handshakes so the 28-byte
count, the length-byte anchor and the 1-byte fallback are checked
without a Minecraft client or the VPS.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Make the role ship the file

**Files:**
- Modify: `ansible/roles/caddy_gateway/tasks/main.yaml`
- Rewrite: `ansible/roles/caddy_gateway/defaults/main.yaml`
- Delete: `ansible/roles/caddy_gateway/templates/Caddyfile.j2`
- Modify: `ansible/playbooks/caddy-gateway.yaml`
- Modify: `ansible/playbooks/composite/edge.yaml`

- [ ] **Step 1: Delete the template**

```fish
git rm ansible/roles/caddy_gateway/templates/Caddyfile.j2
```

`templates/systemd-override.conf.j2` stays.

- [ ] **Step 2: Rewrite the role defaults**

Replace the entire content of `ansible/roles/caddy_gateway/defaults/main.yaml` with:

```yaml
---
# What Caddy serves is NOT configured here. The gateway config is the
# hand-written files/Caddyfile: sites, game servers, the bind IP and the ACME
# email all live in it, in plain Caddyfile syntax. This role only builds a
# Caddy that can parse it and ships both.

# --- Custom build (cross-compiled on the Ansible controller; needs Go there) ---
# Stock Caddy only speaks HTTP. The Minecraft listener in the Caddyfile is raw
# TCP, which needs the caddy-l4 module and therefore a custom xcaddy build.
# Pinned so a rebuild is reproducible and Renovate can propose bumps. The apt
# package stays installed for its unit, its `caddy` user and /etc/caddy; a
# systemd drop-in points ExecStart at the custom binary so an apt upgrade can
# never silently restore a plugin-less Caddy.
caddy_version: "v2.11.7"
caddy_l4_version: "v0.1.2"
caddy_custom_bin: /usr/local/bin/caddy
caddy_build_goos: linux
caddy_build_goarch: amd64
# Version-stamped on the controller, so a bump forces a rebuild while a repeat
# run at the same versions is a no-op.
caddy_build_artifact: "/tmp/caddy-{{ caddy_version }}-l4-{{ caddy_l4_version }}"
```

- [ ] **Step 3: Edit the role tasks**

In `ansible/roles/caddy_gateway/tasks/main.yaml`:

(a) Delete the three assert tasks at the top of the file, i.e. everything from the first `- name: Fail fast on missing gateway config` through the `when: caddy_minecraft_servers | length > 0` line of `Fail fast on an unknown Minecraft fallback`. The file should begin with `---` followed directly by `- name: Install prerequisites for the Caddy apt repository`.

(b) Replace the `Render the Caddyfile` task (the `ansible.builtin.template` one, with its preceding two-line comment) with:

```yaml
# Validated with the custom binary on purpose: the apt one has no layer4 and
# would reject a Caddyfile that is in fact correct.
- name: Install the Caddyfile
  ansible.builtin.copy:
    src: Caddyfile
    dest: /etc/caddy/Caddyfile
    owner: root
    group: root
    mode: "0644"
    validate: "{{ caddy_custom_bin }} validate --adapter caddyfile --config %s"
  notify: Reload Caddy
```

(c) Delete the final task `Next steps -- DNS and firewall for the gateway IP` entirely (it only read the removed variables; the README's "Afterwards" section carries that information). The file now ends with the `Enable and start Caddy` task.

- [ ] **Step 4: Drop the playbook guard**

Replace the entire content of `ansible/playbooks/caddy-gateway.yaml` with:

```yaml
---
# Public reverse-proxy on the edge VPS's second IP. Terminates HTTPS for the
# public hostnames and forwards raw TCP for the game servers, both to homelab
# upstreams over the tailnet (the box is already a tailnet node from the
# tailscale-derp role). Run tailscale-derp FIRST so derper is rebound to the
# first IP, freeing the second IP's :443.
#
# What it serves is the hand-written roles/caddy_gateway/files/Caddyfile.
- name: Configure the public reverse-proxy gateway
  hosts: edge
  become: true
  roles:
    - caddy_gateway
```

- [ ] **Step 5: Fix the composite comment**

In `ansible/playbooks/composite/edge.yaml`, replace the comment block (lines 2–6) with:

```yaml
# Provision the whole edge VPS in one run: harden the host, stand up the DERP
# relay, the bot challenge (no-op unless anubis_enabled), then the public
# gateway. import_playbook paths are relative to this file, so ../ points back
# to the playbooks root.
```

- [ ] **Step 6: Syntax-check**

```fish
cd ansible
ansible-playbook --syntax-check playbooks/caddy-gateway.yaml
ansible-playbook --syntax-check playbooks/composite/edge.yaml
```

Expected: both print `playbook: ...` and exit 0. (A syntax check does not evaluate variables, so the `caddy_anubis_enabled` reference still in `anubis.yaml` does not trip it; Task 4 renames it.)

- [ ] **Step 7: Confirm nothing in the role still reads a removed variable**

```fish
grep -rn 'caddy_sites\|caddy_l4_routes\|caddy_minecraft\|caddy_bind_ip\|caddy_email\|caddy_anubis' ansible/roles/caddy_gateway ansible/playbooks/caddy-gateway.yaml
```

Expected: no output.

- [ ] **Step 8: Commit**

```bash
git add -A ansible/roles/caddy_gateway ansible/playbooks/caddy-gateway.yaml ansible/playbooks/composite/edge.yaml
git commit -m "Ship the Caddyfile as a file instead of rendering it

The role copies files/Caddyfile and validates it with the caddy-l4
build. The asserts that checked the inventory lists go with the lists;
a duplicate listener is now caught by caddy validate.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Inventory and the two shared Anubis variables

The Anubis role borrowed two things from the Caddy role: the `caddy_anubis_enabled` switch and the list of site hostnames (for `REDIRECT_DOMAINS`). Both now live with Anubis.

**Files:**
- Modify: `ansible/roles/anubis/defaults/main.yaml:14-18`
- Modify: `ansible/playbooks/anubis.yaml:11`
- Modify: `ansible/inventory/group_vars/edge.yaml`

- [ ] **Step 1: Anubis owns its switch and its domain list**

In `ansible/roles/anubis/defaults/main.yaml`, replace the `anubis_redirect_domains` entry and its four-line comment with:

```yaml
# Install at all. The Caddyfile's `import anubis` lines assume it is on: with
# it off they would forward_auth to a closed port and every request would 502.
anubis_enabled: false

# Hosts Anubis may send a client back to after a passed challenge. Unset, it
# redirects anywhere the ?redir= parameter says -- an open redirect. List every
# hostname in the Caddyfile that imports the anubis snippet.
anubis_redirect_domains: []
```

In `ansible/playbooks/anubis.yaml`, change the `when:` line to:

```yaml
      when: anubis_enabled | default(false)
```

- [ ] **Step 2: Rewrite the Caddy half of the edge inventory**

In `ansible/inventory/group_vars/edge.yaml`, replace everything from the line `# --- IP split (two public IPs on this box) ---` through the end of the file with:

```yaml
# --- IP split (two public IPs on this box) ---
# derper binds the first; Caddy binds the second. Caddy's side is set in its
# Caddyfile (roles/caddy_gateway/files/Caddyfile, `default_bind` and the
# layer4 listener), not here.
derp_bind_ip: "117.18.125.44"

# The gateway reaches homelab services over the tailnet, so accept the homelab
# subnet routes on this node (overrides the relay role's default of false).
tailscale_accept_routes: true

# Tag the relay carries. Auto-applied by a tagged auth key; kept explicit so a
# non-expiring OAuth client secret also works as the key (OAuth needs the tag).
tailscale_tags: "tag:gateway"

# --- Public gateway ---
# Sites and game servers are NOT listed here. They are the hand-written
# roles/caddy_gateway/files/Caddyfile: add a Minecraft server as one
# `import mc_server` line, a public app as one site block. The file explains
# both. What the inventory still owns is the Caddy build and Anubis.

# Bot challenge in front of the HTTP sites. The Caddyfile's `import anubis`
# lines assume this is on.
anubis_enabled: true
# Every hostname in the Caddyfile that imports anubis. Anubis refuses to
# redirect a passed challenge anywhere else.
anubis_redirect_domains:
  - share.app.fordkuppp.me

# --- Custom Caddy build (needs Go on the Ansible controller) ---
# Renovate tracks both.
caddy_version: "v2.11.7"
caddy_l4_version: "v0.1.2"
```

The first ~30 lines of the file (the header comment, `tailscale_authkey`, `derp_hostname`, `derper_version`) are untouched.

- [ ] **Step 3: Confirm no inventory or playbook still reads a removed variable**

```fish
grep -rn 'caddy_sites\|caddy_l4_routes\|caddy_minecraft\|caddy_bind_ip\|caddy_email\|caddy_anubis' ansible --include='*.yaml' --include='*.j2'
```

Expected: exactly one hit, in `ansible/roles/pelican_wings/tasks/main.yaml` (fixed in Task 5). Anything else is a miss.

- [ ] **Step 4: Syntax-check everything that touches the edge group**

```fish
cd ansible
ansible-playbook --syntax-check playbooks/composite/edge.yaml
ansible-playbook --syntax-check playbooks/anubis.yaml
```

Expected: both exit 0.

- [ ] **Step 5: Render the Anubis env in check mode to see the domain list land**

```fish
cd ansible
ansible-playbook --check --diff playbooks/anubis.yaml 2>&1 | grep -A2 -B2 REDIRECT_DOMAINS
```

Expected: either no diff (the rendered value `REDIRECT_DOMAINS=share.app.fordkuppp.me` is already on the box from the Send work) or a diff whose `+` line reads exactly `REDIRECT_DOMAINS=share.app.fordkuppp.me`. A `+REDIRECT_DOMAINS=` with nothing after it means the list did not reach the role.

- [ ] **Step 6: Commit**

```bash
git add ansible/roles/anubis/defaults/main.yaml ansible/playbooks/anubis.yaml ansible/inventory/group_vars/edge.yaml
git commit -m "Move the site list out of the inventory

With the Caddyfile hand-written, the inventory no longer lists sites or
game servers. Anubis keeps its own switch (anubis_enabled) and an
explicit redirect-domain list instead of deriving one from caddy_sites.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Wings' next-steps message

**Files:**
- Modify: `ansible/roles/pelican_wings/tasks/main.yaml:78-90`

- [ ] **Step 1: Point the message at the Caddyfile line**

Replace the `Next steps -- wire this node into the public gateway` task's `msg:` list with:

```yaml
    msg:
      - "Wings API (via the cluster gateway): https://{{ pelican_wings_fqdn }}"
      - "Tailnet IPv4 of this node: {{ tailscale_ipv4 | default('unknown -- run the tailscale_node role') }}"
      - "Expose a server: add one line inside the 25565 listener of ansible/roles/caddy_gateway/files/Caddyfile:"
      - "    import mc_server <label> {{ tailscale_ipv4 | default('<tailnet-ip>') }}:<port>"
      - "Players connect to <label>.games.fordkuppp.me. All servers share 25565, so no new DNS record and no new firewall port."
      - "Then: ansible-playbook playbooks/caddy-gateway.yaml"
```

- [ ] **Step 2: Syntax-check and grep**

```fish
cd ansible
ansible-playbook --syntax-check playbooks/pelican-wings.yaml
grep -rn 'caddy_minecraft' ansible
```

Expected: syntax check exits 0; grep prints nothing.

- [ ] **Step 3: Commit**

```bash
git add ansible/roles/pelican_wings/tasks/main.yaml
git commit -m "Tell the Wings operator which Caddyfile line to add

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: Documentation

Prose that told the reader to add an inventory entry now tells them to add a Caddyfile line. Specs and plans under `docs/superpowers/` are dated records and stay as they are.

**Files:**
- Modify: `ansible/README.md`
- Modify: `docs/runbooks/pelican.md:111-117, 150`
- Modify: `docs/runbooks/send.md:93-96`
- Modify: `docs/ip-plan.md:74`
- Modify: `kubernetes/apps/dns/records.yaml:31, 49-50`

- [ ] **Step 1: README — the intro paragraph**

In the `## Provision the whole edge box` section of `ansible/README.md`, replace the sentence that ends `then the gateway (which no-ops until \`caddy_sites\`, \`caddy_l4_routes\` or \`caddy_minecraft_servers\` is set):` so the paragraph reads:

```markdown
`composite/edge.yaml` runs the full stack on the `edge` group in order --
baseline hardening, the DERP relay, the Anubis bot challenge (no-op unless
`anubis_enabled`), then the gateway:
```

- [ ] **Step 2: README — the caddy-gateway section**

Replace everything from the `## caddy-gateway` heading up to (not including) the `### Scope` heading that precedes `## anubis` with:

````markdown
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

````

- [ ] **Step 3: README — the Anubis bullet**

In the `## anubis` section, change:

```markdown
The playbook keys off `caddy_anubis_enabled`, the same switch that makes the
Caddy role emit the `forward_auth` blocks, so the two cannot drift apart.
Settings worth knowing:
```

to:

```markdown
The playbook keys off `anubis_enabled`. The Caddyfile's `import anubis` lines
assume it is on -- with Anubis absent they would `forward_auth` to a closed port
and every request would 502 -- so turn both off together. Settings worth
knowing:
```

and change the bullet:

```markdown
- `REDIRECT_DOMAINS` is derived from `caddy_sites`, closing the open redirect
  Anubis warns about when it is unset.
```

to:

```markdown
- `REDIRECT_DOMAINS` is `anubis_redirect_domains` in `group_vars/edge.yaml`:
  every hostname whose site block imports the anubis snippet. Unset, Anubis
  warns about an open redirect.
```

- [ ] **Step 4: runbooks/pelican.md**

Replace step 1 of `## 10. Public exposure` (the numbered item that starts `1. Add the server to \`caddy_minecraft_servers\`` and its YAML block) with:

````markdown
1. Add one line inside the `25565` listener of
   `ansible/roles/caddy_gateway/files/Caddyfile`, using the tailnet IP from
   step 7. The label becomes the hostname players type:

   ```caddyfile
   import mc_server mc 100.x.y.z:25565
   ```

   Then prove it on the controller before touching the VPS:
   `python3 ansible/roles/caddy_gateway/tests/mc_routing.py /tmp/caddy-v2.11.7-l4-v0.1.2`
````

In the verification table, change the `Hostname routing` row to:

```markdown
| Hostname routing | each `import mc_server <label>` line reaches its own server at `<label>.games.fordkuppp.me:25565` |
```

- [ ] **Step 5: runbooks/send.md**

Replace step 2 of the "add another app" list (the one beginning `2. A \`caddy_sites\` entry`) with:

```markdown
2. A site block in `ansible/roles/caddy_gateway/files/Caddyfile` -- copy the
   `share.app.fordkuppp.me` block and change the hostname in both places --
   plus the hostname in `anubis_redirect_domains` in
   `ansible/inventory/group_vars/edge.yaml`, then
   `ansible-playbook playbooks/caddy-gateway.yaml` and
   `ansible-playbook playbooks/anubis.yaml`. Leave out the `import anubis`
   line to skip the bot challenge for that app.
```

- [ ] **Step 6: ip-plan.md**

Change the sentence `A public HTTP app is an HTTPRoute on the gateway's \`https-public\` listener plus a \`caddy_sites\` entry; the wildcard already resolves it.` to:

```markdown
A public HTTP app is an HTTPRoute on the gateway's `https-public`
listener plus a site block in `ansible/roles/caddy_gateway/files/Caddyfile`;
the wildcard already resolves it.
```

- [ ] **Step 7: records.yaml comments**

In `kubernetes/apps/dns/records.yaml`, change the `*.games` comment line `# Adding a server is then an Ansible change alone -- no record per server.` to:

```yaml
    # Adding a server is then one line in the Caddyfile -- no record per server.
```

and the `*.app` comment `# Wildcard, like *.games: a public HTTP app is then a caddy_sites entry on` / `# the VPS plus an HTTPRoute on the https-public listener, with no DNS step.` to:

```yaml
    # Wildcard, like *.games: a public HTTP app is then a site block in the
    # VPS's Caddyfile plus an HTTPRoute on the https-public listener, with no
    # DNS step.
```

- [ ] **Step 8: Final sweep**

```fish
grep -rn 'caddy_sites\|caddy_l4_routes\|caddy_minecraft\|caddy_bind_ip\|caddy_anubis' --include='*.md' --include='*.yaml' --include='*.j2' . | grep -v 'docs/superpowers/'
```

Expected: no output. Hits under `docs/superpowers/` are the dated records and are expected.

- [ ] **Step 9: Commit**

```bash
git add ansible/README.md docs/runbooks/pelican.md docs/runbooks/send.md docs/ip-plan.md kubernetes/apps/dns/records.yaml
git commit -m "Document the Caddyfile as the place sites and servers live

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Deploy and verify end to end

Nothing before this task touches the VPS. Do this with the operator present: it reloads the public gateway.

- [ ] **Step 1: Dry run**

```fish
cd ansible
ansible-playbook --check --diff playbooks/caddy-gateway.yaml
```

Expected: the only `changed` task is `Install the Caddyfile`, and its diff replaces the rendered file with the hand-written one. The build task is skipped (`creates:` satisfied), the binary and drop-in are unchanged. If the drop-in or binary shows as changed, stop and find out why before continuing -- that would restart Caddy rather than reload it.

- [ ] **Step 2: Apply**

```fish
cd ansible
ansible-playbook playbooks/caddy-gateway.yaml
ansible-playbook playbooks/anubis.yaml
```

Expected: `caddy-gateway` reports `changed=1` (the Caddyfile) and the `Reload Caddy` handler runs; `anubis` reports `changed=0` (the redirect-domain list renders to the same value as before).

- [ ] **Step 3: Confirm on the box**

```fish
cd ansible
ansible edge -b -m shell -a '/usr/local/bin/caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile && systemctl is-active caddy && ss -ltnp | grep -E "117.18.125.45:(25565|443|80) "'
```

Expected: `Valid configuration`, `active`, and three listening sockets all owned by `caddy`, all on `117.18.125.45`, none on `117.18.125.44`.

- [ ] **Step 4: Minecraft, by name and by IP, from the controller**

A status ping to the real server returns a JSON status packet. This proves the whole path (DNS → Caddy → tailnet → Wings → server) without a game client:

```fish
python3 - <<'PY'
import socket, json
def varint(n):
    out = b""
    while True:
        b = n & 0x7F; n >>= 7; out += bytes([b | (0x80 if n else 0)])
        if not n: return out
def ping(host, connect_to):
    body = b"\x00" + varint(772) + varint(len(host)) + host.encode() + (25565).to_bytes(2, "big") + b"\x01"
    s = socket.create_connection((connect_to, 25565), timeout=5); s.sendall(varint(len(body)) + body + b"\x01\x00")
    data = b""
    while len(data) < 64: data += s.recv(4096)
    s.close()
    return "motd/version JSON" if b'"version"' in data else data[:40]
print("by name  :", ping("mc.games.fordkuppp.me", "mc.games.fordkuppp.me"))
print("unknown  :", ping("nope.games.fordkuppp.me", "mc.games.fordkuppp.me"))
print("by raw IP:", ping("117.18.125.45", "117.18.125.45"))
PY
```

Expected: all three lines say `motd/version JSON`. The second and third go through the fallback route, which proxies to the same single server today. If "by name" works but the other two time out, the fallback matcher was lost.

- [ ] **Step 5: The HTTP site still works**

```fish
curl -sI https://share.app.fordkuppp.me/ | head -1
```

Expected: `HTTP/2 307` (Anubis challenge redirect for a cookie-less client) or `HTTP/2 200`. A `502` means the Anubis upstream is unreachable: check `systemctl status anubis@caddy` on the box.

- [ ] **Step 6: Idempotence**

```fish
cd ansible
ansible-playbook playbooks/caddy-gateway.yaml
```

Expected: `changed=0`.

- [ ] **Step 7: Nothing to commit**

This task changes no files. If anything had to be fixed to get here, commit that fix on its own with a message saying what the live run revealed.

---

## Self-review notes

- **Coverage.** Static file (T1), proof (T2), role wiring (T3), inventory and the shared Anubis vars (T4), the Wings hint (T5), prose (T6), live (T7). The `close` fallback option survives as a documented edit to the file rather than a variable. The `caddy_l4_routes` generic-port feature is dropped with nothing replacing it: it has no users, and a future one is a four-line listener in the file.
- **Names used consistently:** snippet `mc_server`, args `{args[0]}` = label, `{args[1]}` = upstream; variables `anubis_enabled`, `anubis_redirect_domains`; file `ansible/roles/caddy_gateway/files/Caddyfile`; test `ansible/roles/caddy_gateway/tests/mc_routing.py`; build artifact `/tmp/caddy-v2.11.7-l4-v0.1.2`.
- **Risk worth naming.** Task 4 renames `caddy_anubis_enabled`, which the uncommitted Send/Anubis work introduced. If that work changes shape before this plan runs, re-check `grep -rn anubis_enabled ansible` after Task 4 rather than trusting the line numbers here.
