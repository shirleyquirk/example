"""Layer 4 unit tests."""

from __future__ import annotations

from usb_blaster_decode.jtag_bits import JtagSample
from usb_blaster_decode.tap import TapDecoder, TapState, decode_shifts


def _tms_seq_to_shift_dr() -> list[int]:
    # From TLR -> RTI(0) -> SelectDR(1) -> CaptureDR(0) -> ShiftDR(0)
    # = 0,1,0,0
    return [0, 1, 0, 0]


def _tms_seq_exit_dr() -> list[int]:
    # ShiftDR -(1)-> Exit1DR -(1)-> UpdateDR -(0)-> RunTestIdle
    return [1, 1, 0]


def _samples(tms_bits, tdi_bits, tdo_bits=None) -> list[JtagSample]:
    out = []
    for i, (m, d) in enumerate(zip(tms_bits, tdi_bits)):
        t = None if tdo_bits is None else tdo_bits[i]
        out.append(JtagSample(tms=m, tdi=d, tdo=t, out_offset=i))
    return out


def test_simple_dr_shift():
    # Walk to ShiftDR, shift 4 bits with TDI=1010, exit via TMS=1.
    tms = _tms_seq_to_shift_dr() + [0, 0, 0, 1]
    tdi = [0, 0, 0, 0] + [1, 0, 1, 1]  # last bit is the one clocked on exit
    samples = _samples(tms, tdi)
    events = decode_shifts(samples)
    assert len(events) == 1
    e = events[0]
    assert e.kind == "DR"
    assert e.length == 4
    # LSB-first: 1,0,1,1 -> 0b1101 = 13
    assert e.tdi == 0b1101
    assert e.tdo is None
    assert e.entered_state == TapState.ShiftDR
    assert e.exited_state == TapState.Exit1DR


def test_tdo_captured_when_all_samples_read():
    tms = _tms_seq_to_shift_dr() + [0, 0, 0, 1]
    tdi = [0, 0, 0, 0] + [1, 0, 0, 0]
    tdo = [0, 0, 0, 0] + [0, 1, 0, 1]
    samples = _samples(tms, tdi, tdo)
    events = decode_shifts(samples)
    assert events[0].tdo == 0b1010


def test_tdo_is_none_if_any_sample_missing_tdo():
    tms = _tms_seq_to_shift_dr() + [0, 0, 0, 1]
    tdi = [0, 0, 0, 0] + [1, 0, 0, 0]
    tdo = [0, 0, 0, 0] + [None, 1, 0, 1]
    samples = _samples(tms, tdi, tdo)
    events = decode_shifts(samples)
    assert events[0].tdo is None


def test_decoder_is_resumable_across_chunks():
    tms = _tms_seq_to_shift_dr() + [0, 0, 0, 1]
    tdi = [0, 0, 0, 0] + [1, 1, 0, 0]
    samples = _samples(tms, tdi)
    dec = TapDecoder()
    e1 = dec.feed(samples[:5])
    e2 = dec.feed(samples[5:])
    assert e1 == []
    assert len(e2) == 1
    assert e2[0].length == 4
    assert e2[0].tdi == 0b0011


def test_ir_then_dr_back_to_back():
    # TLR -(0)-> RTI -(1)-> SelectDR -(1)-> SelectIR -(0)-> CaptureIR
    # -(0)-> ShiftIR -(0,0,1)-> shifts 3 bits, exits.
    # then ExitIR(1) -> UpdateIR -(1)-> SelectDR -(0)-> CaptureDR
    # -(0)-> ShiftDR -(0,0,1) -> shifts 3 bits, exits.
    tms = (
        [0, 1, 1, 0, 0, 0, 0, 1]  # walk to Shift-IR and shift 3 bits
        + [1, 1, 0, 0, 0, 0, 1]   # walk to Shift-DR and shift 3 bits
    )
    tdi = (
        [0, 0, 0, 0, 0, 1, 0, 1]  # IR bits LSB-first: 1,0,1 -> 0b101
        + [0, 0, 0, 0, 0, 1, 1]   # DR bits LSB-first: 0,1,1 -> 0b110
    )
    samples = _samples(tms, tdi)
    events = decode_shifts(samples)
    assert [e.kind for e in events] == ["IR", "DR"]
    assert events[0].length == 3 and events[0].tdi == 0b101
    assert events[1].length == 3 and events[1].tdi == 0b110
