"""Hardware-required test scaffolding.

These tests are skipped unless ``USB_BLASTER_HW=1`` is set in the env.
On the lab machine you'd normally do::

    USB_BLASTER_HW=1 \\
    USB_BLASTER_CABLE="USB-Blaster on local host" \\
    USB_BLASTER_USBMON=usbmon0 \\
    USB_BLASTER_CAPTURE_SOCK=/run/usb-blaster-decode/capture.sock \\
    pytest tests/hw

If ``USB_BLASTER_CAPTURE_SOCK`` is unset, the capture-dependent tests
self-skip — that lets you run the wrapper-only tests without the
capture-server installed.
"""

from __future__ import annotations

import os

import pytest


def _hw_enabled() -> bool:
    return os.environ.get("USB_BLASTER_HW", "0") == "1"


@pytest.fixture(scope="session")
def aji_client():
    if not _hw_enabled():
        pytest.skip("set USB_BLASTER_HW=1 to run hardware tests")
    from aji_pyclient import AjiClient

    return AjiClient()


@pytest.fixture(scope="session")
def selected_cable(aji_client):
    cable = os.environ.get("USB_BLASTER_CABLE")
    return aji_client.select_cable(cable=cable)


@pytest.fixture(scope="session")
def selected_device(aji_client, selected_cable):
    device = os.environ.get("USB_BLASTER_DEVICE")
    return aji_client.select_device(selected_cable, device=device)


@pytest.fixture(scope="session")
def open_device(aji_client, selected_cable, selected_device):
    """Open the device with a permissive claim list. Greedy chain lock for the
    duration of the session so other clients can't race us mid-test."""
    from aji_pyclient import AjiClaim, ClaimType

    # Weak-claim everything: lets us issue arbitrary IR/DR ops in tests
    # without enumerating per-device instructions ahead of time.
    claims = [AjiClaim(ClaimType.IR_WEAK, ~0 & 0xFFFFFFFF)]
    with aji_client.lock_chain(selected_cable):
        with aji_client.open_device(
            selected_cable, selected_device, claims,
            application_name="usb_blaster_decode_tests",
        ) as dev:
            yield dev


@pytest.fixture
def capture():
    """Yields a CaptureSession factory; tests do
    ``with capture() as cap: ...; pcap = cap.pcap_path``."""
    sock = os.environ.get("USB_BLASTER_CAPTURE_SOCK")
    if not sock:
        pytest.skip("set USB_BLASTER_CAPTURE_SOCK to run capture-backed tests")
    iface = os.environ.get("USB_BLASTER_USBMON", "usbmon0")
    from tests.hw.capture_client import CaptureSession

    def _factory():
        return CaptureSession(socket_path=sock, iface=iface)

    return _factory
