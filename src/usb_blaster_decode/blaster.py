"""Layer 2: parse the Altera USB Blaster command/response byte streams.

Input:
    out_bytes: bytes the host sent on the bulk-OUT pipe, in time order
    in_bytes:  bytes the device sent on the bulk-IN pipe, in time order
               (already stripped of FTDI 2-byte modem-status headers; see
               ``pcap_extract``)

Output: a list of ``BlasterEvent``s, one per logical command on the OUT
stream. READ replies are paired up with the IN stream as they are produced.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional


# Bit positions in a bit-bang byte. Match jtag-remote-server's build_command
# and the ixo-jtag spec.
TCK_BIT = 1 << 0
TMS_BIT = 1 << 1
NCE_BIT = 1 << 2
NCS_BIT = 1 << 3
TDI_BIT = 1 << 4
LED_BIT = 1 << 5
READ_BIT = 1 << 6
SHIFT_BIT = 1 << 7


@dataclass(frozen=True)
class BitBangEvent:
    """One bit-bang byte on the OUT pipe."""

    offset: int  # byte offset in the OUT stream
    raw: int     # the raw byte
    tck: int
    tms: int
    tdi: int
    read: bool
    tdo: Optional[int]  # 0/1 if read was set, else None


@dataclass(frozen=True)
class ByteShiftEvent:
    """One byte-shift command (header + data + optional reply)."""

    offset: int          # offset of the header byte in the OUT stream
    length: int          # N, in bytes
    read: bool
    tdi: bytes           # N bytes, LSB-first per byte
    tdo: Optional[bytes] # N bytes if read, else None


BlasterEvent = BitBangEvent | ByteShiftEvent


class BlasterDecodeError(ValueError):
    pass


def parse_blaster_stream(
    out_bytes: bytes,
    in_bytes: bytes = b"",
    *,
    strict: bool = True,
) -> list[BlasterEvent]:
    """Decode an OUT byte stream into events, consuming IN bytes for replies.

    If ``strict`` is True, raise on truncated byte-shift commands or on
    running out of IN bytes for a queued READ. If False, the trailing
    incomplete event is dropped and missing TDO is left as ``None``.
    """
    events: list[BlasterEvent] = []
    out = memoryview(out_bytes)
    inp = memoryview(in_bytes)
    in_pos = 0
    i = 0
    n = len(out)
    while i < n:
        b = out[i]
        if b & SHIFT_BIT:
            length = b & 0x3F
            read = bool(b & READ_BIT)
            if length == 0:
                raise BlasterDecodeError(
                    f"byte-shift header with length=0 at offset {i}"
                )
            data_start = i + 1
            data_end = data_start + length
            if data_end > n:
                if strict:
                    raise BlasterDecodeError(
                        f"truncated byte-shift at offset {i}: need {length} "
                        f"bytes, have {n - data_start}"
                    )
                break
            tdi = bytes(out[data_start:data_end])
            tdo: Optional[bytes] = None
            if read:
                if in_pos + length > len(inp):
                    if strict:
                        raise BlasterDecodeError(
                            f"byte-shift at offset {i} expects {length} TDO "
                            f"bytes but only {len(inp) - in_pos} remain"
                        )
                else:
                    tdo = bytes(inp[in_pos : in_pos + length])
                    in_pos += length
            events.append(
                ByteShiftEvent(
                    offset=i, length=length, read=read, tdi=tdi, tdo=tdo
                )
            )
            i = data_end
        else:
            read = bool(b & READ_BIT)
            tdo: Optional[int] = None
            if read:
                if in_pos >= len(inp):
                    if strict:
                        raise BlasterDecodeError(
                            f"bit-bang READ at offset {i} but IN stream is "
                            f"exhausted"
                        )
                else:
                    # Only bit 0 of the reply byte is the TDO sample; the
                    # firmware sets other bits to noise.
                    tdo = inp[in_pos] & 1
                    in_pos += 1
            events.append(
                BitBangEvent(
                    offset=i,
                    raw=b,
                    tck=(b >> 0) & 1,
                    tms=(b >> 1) & 1,
                    tdi=(b >> 4) & 1,
                    read=read,
                    tdo=tdo,
                )
            )
            i += 1
    return events


def encode_bit_bang(
    *, tck: int, tms: int, tdi: int, read: bool = False
) -> int:
    """Encode a bit-bang byte the same way drivers do (nCE/nCS/LED forced 1)."""
    b = NCE_BIT | NCS_BIT | LED_BIT
    if tck:
        b |= TCK_BIT
    if tms:
        b |= TMS_BIT
    if tdi:
        b |= TDI_BIT
    if read:
        b |= READ_BIT
    return b


def encode_byte_shift(data: bytes, *, read: bool = False) -> bytes:
    """Encode a byte-shift command. ``data`` must be 1..63 bytes."""
    if not 1 <= len(data) <= 63:
        raise ValueError(f"byte-shift length must be 1..63, got {len(data)}")
    header = SHIFT_BIT | (READ_BIT if read else 0) | len(data)
    return bytes([header]) + data
