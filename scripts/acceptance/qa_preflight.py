#!/usr/bin/env python3
"""Real local fixture roundtrips and built heartbeat-writer checks.

Only loopback traffic, ephemeral sockets, private temporary data, and explicit
fixture entrypoints. Never launches the production delegate or contacts NCHU.
"""
import argparse
import errno
import hashlib
import json
from pathlib import Path
import socket
import subprocess
import tempfile
import time

from unattended import validate_health
from verify_report import read_private, strict_json

MARKER = "NETGUARD_QA_PREFLIGHT_OK"
PAYLOAD = bytes(range(256)) * 32


def read_exact(sock, size):
    data = bytearray()
    while len(data) < size:
        part = sock.recv(size - len(data))
        if not part:
            raise ValueError("unexpected stream EOF")
        data.extend(part)
    return bytes(data)


def loopback(family, kind):
    address = "127.0.0.1" if family == socket.AF_INET else "::1"
    with socket.socket(family, kind) as server, socket.socket(family, kind) as client:
        for sock in (server, client):
            sock.settimeout(2)
        if family == socket.AF_INET6:
            server.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            client.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        server.bind((address, 0))
        if kind == socket.SOCK_STREAM:
            server.listen(1)
            client.connect(server.getsockname())
            with server.accept()[0] as peer:
                peer.settimeout(2)
                client.sendall(PAYLOAD)
                received = read_exact(peer, len(PAYLOAD))
                peer.sendall(received)
                returned = read_exact(client, len(PAYLOAD))
        else:
            client.bind((address, 0))
            parts, replies = [], []
            for offset in range(0, len(PAYLOAD), 1024):
                chunk = PAYLOAD[offset:offset+1024]
                if client.sendto(chunk, server.getsockname()) != len(chunk):
                    raise ValueError("short datagram write")
                got, origin = server.recvfrom(2048)
                if origin != client.getsockname() or got != chunk:
                    raise ValueError("datagram source or contents mismatch")
                if server.sendto(got, origin) != len(got):
                    raise ValueError("short echo write")
                reply, origin = client.recvfrom(2048)
                if origin != server.getsockname() or reply != chunk:
                    raise ValueError("datagram response mismatch")
                parts.append(got)
                replies.append(reply)
            received, returned = b"".join(parts), b"".join(replies)
        if received != PAYLOAD or returned != PAYLOAD:
            raise ValueError("payload mismatch")
        return {"status": "payload_roundtrip_verified", "bytes_each_direction": len(PAYLOAD),
                "sha256": hashlib.sha256(PAYLOAD).hexdigest()}


def heartbeat_fixture(app):
    binary = app.resolve() / "Contents/MacOS/NCHUTraffic"
    with tempfile.TemporaryDirectory(prefix="unattended-") as root:
        directory = Path(root) / "health"
        directory.mkdir(mode=0o700)
        command = [str(binary), "--netguard-qa-heartbeat-fixture",
                   "--netguard-qa-health-dir", str(directory)]
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            stdout, _ = process.communicate(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate()
            raise ValueError("heartbeat fixture timed out")
        if process.returncode or b"NETGUARD_HEARTBEAT_FIXTURE_OK" not in stdout.splitlines():
            raise ValueError("heartbeat producer fixture failed")
        path = directory / "heartbeat.json"
        raw = read_private(path, 16384)
        value = strict_json(raw)
        if value.pop("pid") != process.pid or value["tick_count"] != 4 or value["sample_cycles"] != 4:
            raise ValueError("heartbeat identity or progress mismatch")
        if value["persistence_blocked"] is not False or value["safety_hold_ticks"] != 1:
            raise ValueError("recovered safety hold missing")
        try:
            validate_health(value, time.time())
        except ValueError as error:
            if str(error) != "app safety hold or persistence failure":
                raise
        else:
            raise ValueError("recovered safety hold accepted")
        healthy = dict(value, safety_hold_ticks=0)
        validate_health(healthy, time.time())
        # Existing destination is never adopted, even by another fixture.
        repeat = subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True, timeout=15)
        if repeat.returncode != 2 or read_private(path, 16384) != raw:
            raise ValueError("existing heartbeat overwritten")
        return {"status": "producer_consumer_fixture_verified", "ticks": 4,
                "recovered_hold_rejected": True, "existing_report_preserved": True}


def collect(apps):
    if len(apps) != 2:
        raise ValueError("both built variants required")
    sockets = {}
    for name, family in (("ipv4", socket.AF_INET), ("ipv6", socket.AF_INET6)):
        for protocol, kind in (("tcp", socket.SOCK_STREAM), ("udp", socket.SOCK_DGRAM)):
            key = name + "_" + protocol
            try:
                sockets[key] = loopback(family, kind)
            except OSError as error:
                if name == "ipv6" and error.errno in (errno.EAFNOSUPPORT, errno.EADDRNOTAVAIL, errno.EPROTONOSUPPORT):
                    sockets[key] = {"status": "unsupported_review_required"}
                else:
                    raise
    return {"kind": "isolated_preflight", "loopback": sockets,
            "heartbeat": {"legacy": heartbeat_fixture(apps[0]), "module": heartbeat_fixture(apps[1])},
            "scope": "loopback_payload_and_fixture_only_not_physical_accounting",
            "full_device_acceptance": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, action="append", required=True)
    args = parser.parse_args()
    try:
        result = collect(args.app)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        parser.exit(1, "Isolated QA preflight failed.\n")
    print(json.dumps(result, sort_keys=True))
    print(MARKER)


if __name__ == "__main__":
    main()
