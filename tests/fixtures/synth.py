"""Synthesise blaster byte streams the same way jtag-remote-server would.

This file is a faithful Python port of the encoding side of
``vendor/jtag-remote-server/src/usb_blaster.cpp`` so we can drive the
decoder end-to-end without real hardware. We treat the C code as the
spec and check that the decoder recovers the original IR/DR shifts.

The functions exported here mirror the public C entry points the upper
JTAG layer in jtag-remote-server calls:

    jtag_tms_seq(data, num_bits)
    jtag_scan_chain_send(data, num_bits, flip_tms, do_read)

Returned bytes are exactly what the C code would push to the FTDI bulk
OUT endpoint.
"""

from __future__ import annotations

from dataclasses import dataclass

from usb_blaster_decode.blaster import encode_bit_bang, encode_byte_shift


# Match jtag-remote-server's MAX_PACKET_SIZE (32). The protocol allows up
# to 63; this is a self-imposed limit in that codebase and we mirror it
# so byte-shift chunking matches.
MAX_PACKET_SIZE = 32


@dataclass
class SynthDevice:
    """Models the TDO behaviour of a synthetic JTAG device.

    For now this just records what was clocked in and returns a
    user-supplied TDO pattern bit-for-bit. Good enough for testing the
    decoder, since the decoder is meant to be transparent to TDO content.
    """

    tdo_bits: list[int]   # in clock order
    pos: int = 0

    def sample_n(self, n: int) -> list[int]:
        out = self.tdo_bits[self.pos : self.pos + n]
        self.pos += n
        # Pad with zeros if we ran past the supplied pattern.
        while len(out) < n:
            out.append(0)
        return out


def _bit(data: bytes, i: int) -> int:
    return (data[i // 8] >> (i % 8)) & 1


def synth_jtag_tms_seq(data: bytes, num_bits: int) -> tuple[bytes, bytes]:
    """Port of usb_blaster_jtag_tms_seq. Returns (out_bytes, in_bytes).

    The TMS-seq path never sets READ, so ``in_bytes`` is always empty.
    """
    out = bytearray()
    bit = 0
    for i in range(num_bits):
        bit = _bit(data, i)
        out.append(encode_bit_bang(tck=0, tms=bit, tdi=0, read=False))
        out.append(encode_bit_bang(tck=1, tms=bit, tdi=0, read=False))
    # Trailing TCK=0 to leave the line low.
    out.append(encode_bit_bang(tck=0, tms=bit, tdi=0, read=False))
    return bytes(out), b""


def synth_jtag_scan_chain_send(
    data: bytes,
    num_bits: int,
    *,
    flip_tms: bool,
    do_read: bool,
    device: SynthDevice | None = None,
) -> tuple[bytes, bytes]:
    """Port of usb_blaster_jtag_scan_chain_send.

    If ``do_read``, the IN bytes are computed from ``device``. Without a
    device, ``do_read`` is still allowed and IN bytes are all zero (a
    quiet TDO) — useful for tests that only inspect TDI.
    """
    bulk_bits = num_bits - 1 if flip_tms else num_bits
    out = bytearray()
    inp = bytearray()

    length_in_bytes = bulk_bits // 8

    # Whole-byte chunks via byte-shift.
    i = 0
    while i < length_in_bytes:
        trans = min(length_in_bytes - i, MAX_PACKET_SIZE)
        chunk = data[i : i + trans]
        out += encode_byte_shift(chunk, read=do_read)
        if do_read:
            tdo_bytes = bytearray()
            for byte_idx in range(trans):
                bits = (
                    device.sample_n(8)
                    if device is not None
                    else [0] * 8
                )
                v = 0
                for b_idx, bit in enumerate(bits):
                    v |= (bit & 1) << b_idx
                tdo_bytes.append(v)
            inp += bytes(tdo_bytes)
        i += trans

    # Tail bits (less than 8) via bit-bang.
    rem = bulk_bits % 8
    if rem:
        for j in range(rem):
            offset = length_in_bytes * 8 + j
            bit = _bit(data, offset)
            out.append(encode_bit_bang(tck=0, tms=0, tdi=bit, read=False))
            out.append(encode_bit_bang(tck=1, tms=0, tdi=bit, read=do_read))
            if do_read:
                tdo = (
                    device.sample_n(1)[0] if device is not None else 0
                )
                # Reply byte: only bit 0 is meaningful; rest is firmware noise.
                # We use 0 for the noise here, real hardware varies.
                inp.append(tdo & 1)

    # Optional flip-TMS final bit.
    if flip_tms:
        last_bit = _bit(data, num_bits - 1)
        out.append(encode_bit_bang(tck=0, tms=1, tdi=last_bit, read=False))
        out.append(encode_bit_bang(tck=1, tms=1, tdi=last_bit, read=do_read))
        out.append(encode_bit_bang(tck=0, tms=1, tdi=last_bit, read=False))
        if do_read:
            tdo = device.sample_n(1)[0] if device is not None else 0
            inp.append(tdo & 1)

    return bytes(out), bytes(inp)


def concat(*pairs: tuple[bytes, bytes]) -> tuple[bytes, bytes]:
    """Concatenate multiple (out, in) byte-stream pairs in order."""
    out = bytearray()
    inp = bytearray()
    for o, i in pairs:
        out += o
        inp += i
    return bytes(out), bytes(inp)
