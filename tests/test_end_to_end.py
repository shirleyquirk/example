"""End-to-end: synth blaster bytes the way jtag-remote-server would, then
run them through the full decoder stack and check the recovered shifts.

This is the strongest test we can run without real hardware: the producer
side mirrors ``vendor/jtag-remote-server/src/usb_blaster.cpp``, the
consumer is the decoder, and we check they agree on what was shifted.
"""

from __future__ import annotations

from usb_blaster_decode.blaster import parse_blaster_stream
from usb_blaster_decode.jtag_bits import samples_from_blaster_events
from usb_blaster_decode.tap import TapDecoder, TapState, decode_shifts

from tests.fixtures.synth import (
    SynthDevice,
    concat,
    synth_jtag_scan_chain_send,
    synth_jtag_tms_seq,
)


def _decode(out_bytes: bytes, in_bytes: bytes, *, initial=TapState.TestLogicReset):
    events = parse_blaster_stream(out_bytes, in_bytes)
    samples = samples_from_blaster_events(events)
    return decode_shifts(samples, initial=initial)


def test_jtag_probe_devices_recovers_combined_dr_shift():
    # Replays the relevant tail of jtag_probe_devices() in common.cpp:
    #   - goto TLR
    #   - TLR -> ShiftIR, shift 128 ones, exit via flip_tms
    #   - Exit1IR -> ShiftDR via TMS seq 1100
    #   - shift 8 zeros, flip_tms=false  (stays in ShiftDR)
    #   - shift 8 ones with read, flip_tms=true (now exits)
    #
    # Crucially, the two DR scan_chain_send calls are NOT separated by a
    # TMS transition. On real silicon they are one continuous 16-bit DR
    # shift, so that's exactly what the decoder reports. The TDO field is
    # None because READ was off for the first half — we can't claim to
    # know what the TAP drove on TDO during those cycles.
    MAX_TAPS = 8

    out, inp = concat(
        synth_jtag_tms_seq(b"\x1f", 5),                       # goto TLR
        synth_jtag_tms_seq(b"\x06", 5),                       # TLR -> ShiftIR
        synth_jtag_scan_chain_send(
            b"\xff" * 16, 128, flip_tms=True, do_read=False   # IR=ones
        ),
        synth_jtag_tms_seq(b"\x03", 4),                       # Exit1IR -> ShiftDR
        synth_jtag_scan_chain_send(
            b"\x00", MAX_TAPS, flip_tms=False, do_read=False  # 8 zeros, no read
        ),
    )

    # End-of-chain marker: 8 ones in, 0xfe out (only bit 0 is the device).
    device = SynthDevice(tdo_bits=[0, 1, 1, 1, 1, 1, 1, 1])
    out2, inp2 = synth_jtag_scan_chain_send(
        b"\xff", MAX_TAPS, flip_tms=True, do_read=True, device=device
    )

    shifts = _decode(out + out2, inp + inp2)
    assert [(s.kind, s.length) for s in shifts] == [("IR", 128), ("DR", 16)]
    assert shifts[0].tdi == (1 << 128) - 1
    # Combined DR: 8 zeros (bits 0-7) then 8 ones (bits 8-15).
    assert shifts[1].tdi == 0xFF00
    # Mixed-read shift -> TDO is unknown.
    assert shifts[1].tdo is None


def test_read_only_dr_shift_recovers_tdo_byte():
    # Cleaner end-to-end of TDO recovery: walk to ShiftDR, do one read-only
    # 8-bit shift, exit. This is what we'd want in a v1 IDCODE-style probe
    # written carefully enough to keep the read window contiguous.
    device = SynthDevice(tdo_bits=[0, 1, 1, 1, 1, 1, 1, 1])  # 0xfe LSB-first
    out, inp = concat(
        synth_jtag_tms_seq(b"\x1f", 5),  # goto TLR
        synth_jtag_tms_seq(b"\x02", 4),  # TLR -> ShiftDR
        synth_jtag_scan_chain_send(
            b"\xff", 8, flip_tms=True, do_read=True, device=device
        ),
    )
    shifts = _decode(out, inp)
    assert len(shifts) == 1
    assert shifts[0].kind == "DR"
    assert shifts[0].length == 8
    assert shifts[0].tdi == 0xFF
    assert shifts[0].tdo == 0xFE


def test_byte_aligned_dr_shift_round_trip():
    # 16 bits of TDI with 16 bits of TDO via byte-shift mode.
    payload = b"\xde\xad"
    expected_tdo = b"\xbe\xef"
    device = SynthDevice(
        tdo_bits=[(expected_tdo[i // 8] >> (i % 8)) & 1 for i in range(16)]
    )

    out, inp = concat(
        synth_jtag_tms_seq(b"\x1f", 5),  # goto TLR
        synth_jtag_tms_seq(b"\x02", 4),  # TLR -> ShiftDR (LSB-first 0,1,0,0)
        synth_jtag_scan_chain_send(
            payload, 16, flip_tms=True, do_read=True, device=device
        ),
    )
    shifts = _decode(out, inp)
    assert len(shifts) == 1
    assert shifts[0].kind == "DR"
    assert shifts[0].length == 16
    assert shifts[0].tdi == 0xADDE  # bytes b"\xde\xad" interpreted LSB-first
    assert shifts[0].tdo == 0xEFBE


def test_unaligned_dr_shift_uses_bit_bang_tail():
    # 11 bits: forces 1 byte of byte-shift + 3 tail bits via bit-bang.
    payload = b"\xa5\x07"  # 11 LSB-first bits: 1,0,1,0,0,1,0,1, 1,1,1
    out, inp = concat(
        synth_jtag_tms_seq(b"\x1f", 5),  # goto TLR
        synth_jtag_tms_seq(b"\x02", 4),  # TLR -> ShiftDR
        synth_jtag_scan_chain_send(
            payload, 11, flip_tms=True, do_read=False
        ),
    )
    shifts = _decode(out, inp)
    assert len(shifts) == 1
    assert shifts[0].length == 11
    # Reconstruct the 11-bit value LSB-first from payload.
    expected = 0
    for i in range(11):
        expected |= ((payload[i // 8] >> (i % 8)) & 1) << i
    assert shifts[0].tdi == expected


def test_chunk_boundary_byte_shift_at_max_packet():
    # 32 byte-shift bytes is exactly MAX_PACKET_SIZE; jtag-remote-server
    # emits this as one byte-shift command. 33 forces a split — 32 + 1.
    payload = bytes(range(33))
    out, inp = concat(
        synth_jtag_tms_seq(b"\x1f", 5),
        synth_jtag_tms_seq(b"\x02", 4),
        synth_jtag_scan_chain_send(
            payload, len(payload) * 8, flip_tms=True, do_read=False
        ),
    )
    shifts = _decode(out, inp)
    assert len(shifts) == 1
    assert shifts[0].length == 33 * 8
    expected = int.from_bytes(payload, "little")
    assert shifts[0].tdi == expected
