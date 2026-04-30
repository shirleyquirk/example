#!/usr/bin/env python3
"""Outside-the-bwrap capture server.

Listens on a unix socket. Accepts a tiny JSON protocol:

    {"op": "start", "iface": "usbmon0"}
        -> {"status": "ok", "id": "<uuid>", "pcap": "<abs path>"}

    {"op": "stop", "id": "<uuid>"}
        -> {"status": "ok", "bytes": <pcap size>}

    {"op": "list"}
        -> {"status": "ok", "captures": [{"id":..., "iface":..., "pcap":...}, ...]}

The server validates ``iface`` against an allowlist (passed on the
command line) and execs a single fixed wrapper script via sudo. The
client cannot influence the output path or any other tshark flag — that
is the whole point of the shim wrapper script.

The pcap directory must be world-readable so the inside-bwrap test
process can read it (the bwrap config bind-mounts it read-only).

Run this on the host with:

    capture-server.py \\
        --socket /run/usb-blaster-decode/capture.sock \\
        --pcap-dir /var/lib/usb-blaster-decode \\
        --capture-cmd /usr/local/bin/usb-blaster-capture.sh \\
        --iface usbmon0 --iface usbmon1
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import signal
import socket
import socketserver
import subprocess
import sys
import threading
import uuid
from dataclasses import dataclass


_IFACE_RE = re.compile(r"^usbmon\d{1,2}$")


@dataclass
class Capture:
    capture_id: str
    iface: str
    pcap_path: pathlib.Path
    proc: subprocess.Popen


class CaptureRegistry:
    def __init__(self) -> None:
        self._captures: dict[str, Capture] = {}
        self._lock = threading.Lock()

    def add(self, c: Capture) -> None:
        with self._lock:
            self._captures[c.capture_id] = c

    def pop(self, capture_id: str) -> Capture | None:
        with self._lock:
            return self._captures.pop(capture_id, None)

    def list(self) -> list[Capture]:
        with self._lock:
            return list(self._captures.values())


class Handler(socketserver.StreamRequestHandler):
    server: "CaptureServer"

    def handle(self) -> None:
        try:
            line = self.rfile.readline()
            if not line:
                return
            try:
                msg = json.loads(line.decode("utf-8"))
            except Exception as e:
                self._reply({"status": "error", "msg": f"bad json: {e}"})
                return
            op = msg.get("op")
            if op == "start":
                self._handle_start(msg)
            elif op == "stop":
                self._handle_stop(msg)
            elif op == "list":
                self._handle_list()
            else:
                self._reply({"status": "error", "msg": f"unknown op {op!r}"})
        except Exception as e:
            self._reply({"status": "error", "msg": f"server error: {e}"})

    def _reply(self, obj: dict) -> None:
        self.wfile.write(json.dumps(obj).encode("utf-8") + b"\n")

    def _handle_start(self, msg: dict) -> None:
        iface = msg.get("iface", "")
        if not isinstance(iface, str) or not _IFACE_RE.match(iface):
            self._reply({"status": "error", "msg": f"bad iface {iface!r}"})
            return
        if iface not in self.server.allowed_ifaces:
            self._reply({"status": "error", "msg": f"iface {iface!r} not allowlisted"})
            return
        capture_id = uuid.uuid4().hex
        pcap_path = self.server.pcap_dir / f"{capture_id}.pcap"
        argv = ["sudo", "-n", str(self.server.capture_cmd), iface, str(pcap_path)]
        try:
            proc = subprocess.Popen(
                argv,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                start_new_session=True,
            )
        except FileNotFoundError as e:
            self._reply({"status": "error", "msg": f"capture cmd not found: {e}"})
            return
        self.server.registry.add(
            Capture(
                capture_id=capture_id,
                iface=iface,
                pcap_path=pcap_path,
                proc=proc,
            )
        )
        self._reply({"status": "ok", "id": capture_id, "pcap": str(pcap_path)})

    def _handle_stop(self, msg: dict) -> None:
        capture_id = msg.get("id")
        if not isinstance(capture_id, str):
            self._reply({"status": "error", "msg": "missing id"})
            return
        c = self.server.registry.pop(capture_id)
        if c is None:
            self._reply({"status": "error", "msg": "unknown capture id"})
            return
        try:
            os.killpg(os.getpgid(c.proc.pid), signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            c.proc.wait(timeout=5.0)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(os.getpgid(c.proc.pid), signal.SIGKILL)
            except ProcessLookupError:
                pass
            c.proc.wait()
        size = c.pcap_path.stat().st_size if c.pcap_path.exists() else 0
        self._reply({"status": "ok", "bytes": size, "pcap": str(c.pcap_path)})

    def _handle_list(self) -> None:
        self._reply(
            {
                "status": "ok",
                "captures": [
                    {
                        "id": c.capture_id,
                        "iface": c.iface,
                        "pcap": str(c.pcap_path),
                    }
                    for c in self.server.registry.list()
                ],
            }
        )


class CaptureServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(
        self,
        socket_path: str,
        *,
        pcap_dir: pathlib.Path,
        capture_cmd: pathlib.Path,
        allowed_ifaces: set[str],
    ) -> None:
        if os.path.exists(socket_path):
            os.unlink(socket_path)
        super().__init__(socket_path, Handler)
        os.chmod(socket_path, 0o660)
        self.pcap_dir = pcap_dir
        self.capture_cmd = capture_cmd
        self.allowed_ifaces = allowed_ifaces
        self.registry = CaptureRegistry()


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--socket", required=True, help="unix socket path to bind")
    p.add_argument("--pcap-dir", required=True, type=pathlib.Path,
                   help="directory the wrapper script may write pcaps into")
    p.add_argument("--capture-cmd", required=True, type=pathlib.Path,
                   help="absolute path to the privileged wrapper script")
    p.add_argument("--iface", action="append", required=True,
                   help="allowlisted usbmon interface (repeatable)")
    args = p.parse_args()

    args.pcap_dir.mkdir(parents=True, exist_ok=True)

    server = CaptureServer(
        args.socket,
        pcap_dir=args.pcap_dir,
        capture_cmd=args.capture_cmd,
        allowed_ifaces=set(args.iface),
    )
    print(f"capture-server listening on {args.socket}", file=sys.stderr)
    print(f"  allowed ifaces: {sorted(server.allowed_ifaces)}", file=sys.stderr)
    print(f"  pcap dir:       {server.pcap_dir}", file=sys.stderr)
    print(f"  capture cmd:    {server.capture_cmd}", file=sys.stderr)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())
