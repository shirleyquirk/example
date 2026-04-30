"""Layer 2 unit tests."""

from __future__ import annotations

import pytest

from usb_blaster_decode.blaster import (
    BitBangEvent,
    BlasterDecodeError,
    ByteShiftEvent,
    encode_bit_bang,
    encode_byte_shift,
    parse_blaster_stream,
)


def test_encode_bit_bang_matches_jtag_remote_server_build_command():
    # build_command(tms=0, tdi=0, tck=0, read=false) => nCE|nCS|LED = 0x2c
    assert encode_bit_bang(tck=0, tms=0, tdi=0) == 0x2C
    # tck=1 sets bit 0 -> 0x2d
    assert encode_bit_bang(tck=1, tms=0, tdi=0) == 0x2D
    # all four jtag pins set, read on
    assert (
        encode_bit_bang(tck=1, tms=1, tdi=1, read=True)
        == 0x2C | 0x01 | 0x02 | 0x10 | 0x40
    )


def test_encode_byte_shift_round_trip():
    raw = encode_byte_shift(b"\xab\xcd", read=True)
    assert raw[0] == 0x80 | 0x40 | 2
    assert raw[1:] == b"\xab\xcd"


def test_parse_bit_bang_no_read():
    out = bytes([encode_bit_bang(tck=0, tms=1, tdi=0)])
    events = parse_blaster_stream(out)
    assert len(events) == 1
    e = events[0]
    assert isinstance(e, BitBangEvent)
    assert (e.tck, e.tms, e.tdi, e.read, e.tdo) == (0, 1, 0, False, None)


def test_parse_bit_bang_with_read_pairs_with_in_byte():
    out = bytes([encode_bit_bang(tck=1, tms=0, tdi=0, read=True)])
    inp = bytes([0x01])  # bit 0 set -> TDO=1
    events = parse_blaster_stream(out, inp)
    assert events[0].tdo == 1


def test_parse_byte_shift_with_read():
    out = encode_byte_shift(b"\x01\x80", read=True)
    inp = b"\x55\xaa"
    events = parse_blaster_stream(out, inp)
    assert len(events) == 1
    e = events[0]
    assert isinstance(e, ByteShiftEvent)
    assert e.length == 2
    assert e.tdi == b"\x01\x80"
    assert e.tdo == b"\x55\xaa"


def test_parse_truncated_byte_shift_raises():
    bad = bytes([0x80 | 4]) + b"\x01\x02"  # claims 4 bytes, only has 2
    with pytest.raises(BlasterDecodeError):
        parse_blaster_stream(bad)


def test_parse_byte_shift_length_zero_is_error():
    with pytest.raises(BlasterDecodeError):
        parse_blaster_stream(bytes([0x80]))


def test_in_underrun_raises_in_strict_mode():
    out = bytes([encode_bit_bang(tck=1, tms=0, tdi=0, read=True)])
    with pytest.raises(BlasterDecodeError):
        parse_blaster_stream(out, b"")


def test_in_underrun_tolerated_in_lenient_mode():
    out = bytes([encode_bit_bang(tck=1, tms=0, tdi=0, read=True)])
    events = parse_blaster_stream(out, b"", strict=False)
    assert events[0].tdo is None


def test_only_low_bit_of_in_byte_is_used_for_bit_bang():
    out = bytes([encode_bit_bang(tck=1, tms=0, tdi=0, read=True)])
    # bit 1 set, bit 0 clear -> TDO is 0 not 1.
    events = parse_blaster_stream(out, b"\x02")
    assert events[0].tdo == 0


def test_mixed_stream_consumes_in_bytes_in_order():
    out = (
        encode_byte_shift(b"\xff", read=True)             # consumes 1 in byte
        + bytes([encode_bit_bang(tck=1, tms=0, tdi=0, read=True)])  # 1 byte
        + encode_byte_shift(b"\x00\x00", read=True)       # 2 in bytes
    )
    inp = b"\xaa\x01\xbb\xcc"
    events = parse_blaster_stream(out, inp)
    assert events[0].tdo == b"\xaa"
    assert events[1].tdo == 1
    assert events[2].tdo == b"\xbb\xcc"
