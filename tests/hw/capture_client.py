"""Inside-bwrap client for the capture-server.

Talks to the capture server over a unix socket. The server is the only
component that ever runs the privileged tshark; the client just asks it
to start/stop. The on-disk pcap is bind-mounted readable into the
container so the test process can decode it directly.
"""

from __future__ import annotations

import json
import socket
import time
from contextlib import contextmanager
from dataclasses import dataclass
from typing import Iterator


class CaptureError(RuntimeError):
    pass


@dataclass
class CaptureSession:
    socket_path: str
    iface: str
    settle_seconds: float = 0.2  # let tshark start writing before we trigger USB traffic

    def _request(self, msg: dict) -> dict:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.connect(self.socket_path)
            s.sendall(json.dumps(msg).encode("utf-8") + b"\n")
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = s.recv(4096)
                if not chunk:
                    break
                buf += chunk
        if not buf:
            raise CaptureError("capture server returned nothing")
        reply = json.loads(buf.decode("utf-8"))
        if reply.get("status") != "ok":
            raise CaptureError(f"capture server: {reply!r}")
        return reply

    @contextmanager
    def __call__(self) -> Iterator["ActiveCapture"]:
        reply = self._request({"op": "start", "iface": self.iface})
        active = ActiveCapture(
            session=self, capture_id=reply["id"], pcap_path=reply["pcap"]
        )
        time.sleep(self.settle_seconds)
        try:
            yield active
        finally:
            active.stop()


@dataclass
class ActiveCapture:
    session: CaptureSession
    capture_id: str
    pcap_path: str
    _stopped: bool = False

    def stop(self) -> int:
        if self._stopped:
            return 0
        reply = self.session._request({"op": "stop", "id": self.capture_id})
        self._stopped = True
        return int(reply.get("bytes", 0))
