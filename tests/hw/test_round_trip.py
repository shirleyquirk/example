"""Capture-backed round-trip: AJI op -> USB pcap -> our decoder.

These tests need both ``USB_BLASTER_HW=1`` and ``USB_BLASTER_CAPTURE_SOCK``
pointing at the capture server's unix socket. They're the actual point of
this whole exercise.

The shape of each test is:

    with capture() as cap:
        with open_device.locked():
            <issue an AJI op with a known shape>
    shifts = decode_pcap(cap.pcap_path)
    assert <shifts match what we asked for>

Note that the decoder's exact view of a single AJI op depends on what
flags/optimisations jtagd applies. We start with the simplest cases
(no optimisation) and document any divergences as we find them.
"""

from __future__ import annotations

import pytest

from usb_blaster_decode import (
    parse_blaster_stream,
    samples_from_blaster_events,
)
from usb_blaster_decode.pcap_extract import extract_streams
from usb_blaster_decode.tap import TapState, decode_shifts


def _decode_pcap(path: str) -> list:
    streams = extract_streams(path)
    events = parse_blaster_stream(
        streams.out_bytes, streams.in_bytes, strict=False
    )
    samples = samples_from_blaster_events(events)
    return decode_shifts(samples, initial=TapState.TestLogicReset)


def test_idcode_round_trip(capture, open_device):
    """Read the IDCODE via AJI, capture USB while doing it, decode, expect
    one DR shift of length 32 carrying the IDCODE."""
    expected_idcode = open_device.device.device_id

    with capture() as cap:
        with open_device.locked():
            open_device.test_logic_reset()  # forces IDCODE to load
            captured = open_device.access_dr(length=32, write=b"\x00\x00\x00\x00")
            open_device.flush()

    assert captured is not None
    aji_idcode = int.from_bytes(captured, "little")
    assert aji_idcode == expected_idcode

    shifts = _decode_pcap(cap.pcap_path)
    dr_shifts = [s for s in shifts if s.kind == "DR" and s.length == 32]
    assert dr_shifts, f"no 32-bit DR shifts decoded; got {[(s.kind, s.length) for s in shifts]}"
    found = [s for s in dr_shifts if s.tdo == expected_idcode]
    assert found, (
        f"expected to find a 32-bit DR shift with TDO=0x{expected_idcode:08x}, "
        f"got {[(s.length, hex(s.tdo or 0)) for s in dr_shifts]}"
    )


@pytest.mark.parametrize("ir_value", [0x0, 0x1, 0x6, 0xF])
def test_access_ir_round_trip(capture, open_device, ir_value):
    ir_len = open_device.device.instruction_length
    if ir_value >= (1 << ir_len):
        pytest.skip(f"ir_value 0x{ir_value:x} doesn't fit in {ir_len}-bit IR")

    with capture() as cap:
        with open_device.locked():
            open_device.access_ir(ir_value)
            open_device.flush()

    shifts = _decode_pcap(cap.pcap_path)
    ir_shifts = [s for s in shifts if s.kind == "IR"]
    assert ir_shifts, "no IR shifts decoded"
    matching = [s for s in ir_shifts if s.tdi & ((1 << ir_len) - 1) == ir_value]
    assert matching, (
        f"no IR shift with low {ir_len} bits = 0x{ir_value:x}; "
        f"got {[hex(s.tdi) for s in ir_shifts]}"
    )


@pytest.mark.parametrize(
    "flags",
    [
        0,
        # Reuse the spec name without importing the enum at collection time
        # so this file imports even when aji_pyclient can't load the shim.
        "AJI_DR_NO_SHORT",
        "AJI_DR_END_PAUSE_DR",
    ],
)
def test_access_dr_flag_effect_on_wire(capture, open_device, flags):
    """Same logical DR scan with different flags. We don't assert exact
    wire-level equality here; we just record the shifts so the test log
    becomes a small reverse-engineering corpus for the flags."""
    from aji_pyclient import DrFlags

    flag_value: DrFlags = (
        DrFlags.NONE if flags == 0
        else DrFlags.NO_SHORT if flags == "AJI_DR_NO_SHORT"
        else DrFlags.END_PAUSE_DR
    )

    with capture() as cap:
        with open_device.locked():
            open_device.test_logic_reset()
            open_device.access_dr(length=32, write=b"\x00\x00\x00\x00", flags=flag_value)
            open_device.flush()

    shifts = _decode_pcap(cap.pcap_path)
    print(f"\n--- flags={flags} ---")
    for s in shifts:
        tdo = f"0x{s.tdo:x}" if s.tdo is not None else "-"
        print(f"  {s.kind} len={s.length} tdi=0x{s.tdi:x} tdo={tdo}")
    # No assertions — pytest -s + this output is the deliverable for now.
