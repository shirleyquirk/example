"""Layer 1 unit tests with a synthesised pcap.

The pcap is built by hand here; this gives us a smoke test of the
header/struct parsing but says nothing about behaviour against a real
hardware capture (URB coalescing, isochronous interleave, FTDI status-byte
edge cases, etc.). Real-capture validation is still TODO.
"""

from __future__ import annotations

import os
import struct
import tempfile

from usb_blaster_decode.pcap_extract import extract_streams


def _build_pcap(records: list[tuple[int, bytes]]) -> bytes:
    """records is a list of (urb_type, body) where body is the full usbmon
    record (header + data) we want emitted."""
    pcap = bytearray()
    # Global header: little-endian magic, v2.4, snaplen=65535, linktype=220
    pcap += struct.pack(
        "<IHHiIII", 0xA1B2C3D4, 2, 4, 0, 0, 65535, 220
    )
    for ts, body in records:
        pcap += struct.pack("<IIII", ts, 0, len(body), len(body))
        pcap += body
    return bytes(pcap)


def _usbmon_record(
    *,
    urb_type: int,
    xfer_type: int,
    epnum: int,
    devnum: int,
    busnum: int,
    data: bytes,
) -> bytes:
    return struct.pack(
        "<QBBBBHBBQiiII8s",
        0xDEADBEEF,
        urb_type,
        xfer_type,
        epnum,
        devnum,
        busnum,
        0,
        0,
        0,
        0,
        0,
        len(data),
        len(data),
        b"\x00" * 8,
    ) + data


def test_round_trip_simple_out_in():
    out_payload = b"\x2c\x2d\x2c"   # bit-bang bytes, no FTDI status header
    in_payload_at_usb_level = b"\x31\x60\x00"  # 2 status + 1 TDO byte
    records = [
        (
            1,
            _usbmon_record(
                urb_type=ord("S"),
                xfer_type=3,         # bulk
                epnum=0x02,          # OUT, ep2
                devnum=4,
                busnum=1,
                data=out_payload,
            ),
        ),
        (
            2,
            _usbmon_record(
                urb_type=ord("C"),
                xfer_type=3,
                epnum=0x81,          # IN, ep1
                devnum=4,
                busnum=1,
                data=in_payload_at_usb_level,
            ),
        ),
    ]
    pcap_bytes = _build_pcap(records)
    with tempfile.NamedTemporaryFile(suffix=".pcap", delete=False) as f:
        f.write(pcap_bytes)
        path = f.name
    try:
        result = extract_streams(path)
    finally:
        os.unlink(path)
    assert result.out_bytes == out_payload
    assert result.in_bytes == b"\x00"   # status header stripped
    assert result.out_endpoint == 2
    assert result.in_endpoint == 1


def test_filters_out_non_bulk_transfers():
    records = [
        (
            1,
            _usbmon_record(
                urb_type=ord("S"),
                xfer_type=2,         # control - should be skipped
                epnum=0x00,
                devnum=4,
                busnum=1,
                data=b"\xff\xff\xff",
            ),
        ),
        (
            2,
            _usbmon_record(
                urb_type=ord("S"),
                xfer_type=3,
                epnum=0x02,
                devnum=4,
                busnum=1,
                data=b"\x2c",
            ),
        ),
    ]
    pcap_bytes = _build_pcap(records)
    with tempfile.NamedTemporaryFile(suffix=".pcap", delete=False) as f:
        f.write(pcap_bytes)
        path = f.name
    try:
        result = extract_streams(path)
    finally:
        os.unlink(path)
    assert result.out_bytes == b"\x2c"
