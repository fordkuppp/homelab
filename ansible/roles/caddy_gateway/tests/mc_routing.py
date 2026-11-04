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
