"""Layer 3 unit tests."""

from __future__ import annotations

from usb_blaster_decode.blaster import (
    encode_bit_bang,
    encode_byte_shift,
    parse_blaster_stream,
)
from usb_blaster_decode.jtag_bits import samples_from_blaster_events


def test_byte_shift_expands_to_eight_lsb_first_samples_per_byte():
    out = encode_byte_shift(b"\xab", read=True)
    inp = b"\xcd"
    samples = samples_from_blaster_events(parse_blaster_stream(out, inp))
    assert len(samples) == 8
    # 0xab = 0b10101011 LSB-first => 1,1,0,1,0,1,0,1
    assert [s.tdi for s in samples] == [1, 1, 0, 1, 0, 1, 0, 1]
    # 0xcd = 0b11001101 LSB-first => 1,0,1,1,0,0,1,1
    assert [s.tdo for s in samples] == [1, 0, 1, 1, 0, 0, 1, 1]
    assert all(s.tms == 0 for s in samples)


def test_bit_bang_pair_emits_one_sample():
    out = bytes(
        [
            encode_bit_bang(tck=0, tms=1, tdi=0),
            encode_bit_bang(tck=1, tms=1, tdi=0, read=True),
        ]
    )
    samples = samples_from_blaster_events(
        parse_blaster_stream(out, b"\x01")
    )
    assert len(samples) == 1
    assert (samples[0].tms, samples[0].tdi, samples[0].tdo) == (1, 0, 1)


def test_unpaired_bytes_emit_no_samples():
    # Three TCK=0 bytes in a row -> no rising edges at all.
    out = bytes(
        [
            encode_bit_bang(tck=0, tms=0, tdi=0),
            encode_bit_bang(tck=0, tms=1, tdi=0),
            encode_bit_bang(tck=0, tms=0, tdi=0),
        ]
    )
    samples = samples_from_blaster_events(parse_blaster_stream(out))
    assert samples == []


def test_pair_must_match_tms_and_tdi():
    # If TMS changes between TCK=0 and TCK=1 we don't pair them.
    out = bytes(
        [
            encode_bit_bang(tck=0, tms=0, tdi=0),
            encode_bit_bang(tck=1, tms=1, tdi=0),
        ]
    )
    samples = samples_from_blaster_events(parse_blaster_stream(out))
    assert samples == []
