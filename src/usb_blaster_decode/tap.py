"""Layer 4: walk the IEEE 1149.1 TAP and emit IR/DR shift events.

A shift event covers the bits clocked while the TAP is in Shift-IR or
Shift-DR, plus the final bit clocked on the TMS=1 transition that exits
Shift-*. That last bit is part of the shifted value on real silicon, and
it is also how jtag-remote-server's ``flip_tms`` path packs its data, so
we follow the same convention.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum, auto
from typing import Iterable, Optional

from .jtag_bits import JtagSample


class TapState(Enum):
    TestLogicReset = auto()
    RunTestIdle = auto()
    SelectDRScan = auto()
    CaptureDR = auto()
    ShiftDR = auto()
    Exit1DR = auto()
    PauseDR = auto()
    Exit2DR = auto()
    UpdateDR = auto()
    SelectIRScan = auto()
    CaptureIR = auto()
    ShiftIR = auto()
    Exit1IR = auto()
    PauseIR = auto()
    Exit2IR = auto()
    UpdateIR = auto()


# Standard JTAG TAP transition table. Mirrors next_state() in
# vendor/jtag-remote-server/src/common.cpp.
_NEXT: dict[TapState, tuple[TapState, TapState]] = {
    TapState.TestLogicReset: (TapState.RunTestIdle, TapState.TestLogicReset),
    TapState.RunTestIdle:    (TapState.RunTestIdle, TapState.SelectDRScan),
    TapState.SelectDRScan:   (TapState.CaptureDR,   TapState.SelectIRScan),
    TapState.CaptureDR:      (TapState.ShiftDR,     TapState.Exit1DR),
    TapState.ShiftDR:        (TapState.ShiftDR,     TapState.Exit1DR),
    TapState.Exit1DR:        (TapState.PauseDR,     TapState.UpdateDR),
    TapState.PauseDR:        (TapState.PauseDR,     TapState.Exit2DR),
    TapState.Exit2DR:        (TapState.ShiftDR,     TapState.UpdateDR),
    TapState.UpdateDR:       (TapState.RunTestIdle, TapState.SelectDRScan),
    TapState.SelectIRScan:   (TapState.CaptureIR,   TapState.TestLogicReset),
    TapState.CaptureIR:      (TapState.ShiftIR,     TapState.Exit1IR),
    TapState.ShiftIR:        (TapState.ShiftIR,     TapState.Exit1IR),
    TapState.Exit1IR:        (TapState.PauseIR,     TapState.UpdateIR),
    TapState.PauseIR:        (TapState.PauseIR,     TapState.Exit2IR),
    TapState.Exit2IR:        (TapState.ShiftIR,     TapState.UpdateIR),
    TapState.UpdateIR:       (TapState.RunTestIdle, TapState.SelectDRScan),
}


def next_state(cur: TapState, tms: int) -> TapState:
    return _NEXT[cur][tms & 1]


@dataclass
class ShiftEvent:
    kind: str            # "IR" or "DR"
    length: int
    tdi: int             # LSB = first bit shifted
    tdo: Optional[int]   # None if any sample in the shift had no TDO
    entered_state: TapState
    exited_state: TapState
    byte_span: tuple[int, int]   # [first, last] OUT byte offsets contributing

    def tdi_hex(self) -> str:
        return f"0x{self.tdi:0{(self.length + 3) // 4}x}"

    def tdo_hex(self) -> Optional[str]:
        if self.tdo is None:
            return None
        return f"0x{self.tdo:0{(self.length + 3) // 4}x}"


class TapDecoder:
    """Stateful TAP walker that yields ShiftEvents.

    The decoder is stateful so a long capture can be decoded in chunks
    without losing the TAP state at chunk boundaries.
    """

    def __init__(self, initial: TapState = TapState.TestLogicReset) -> None:
        self.state = initial
        self._buf_tdi: list[int] = []
        self._buf_tdo: list[Optional[int]] = []
        self._buf_kind: Optional[str] = None
        self._buf_entered_from: Optional[TapState] = None
        self._buf_first_offset: Optional[int] = None
        self._buf_last_offset: Optional[int] = None

    def feed(self, samples: Iterable[JtagSample]) -> list[ShiftEvent]:
        out: list[ShiftEvent] = []
        for s in samples:
            self._step(s, out)
        return out

    def _step(self, s: JtagSample, out: list[ShiftEvent]) -> None:
        cur = self.state
        nxt = next_state(cur, s.tms)

        # Are we accumulating a shift right now? Buffer this bit if either
        # the current state is Shift-* (we sampled a bit while shifting) or
        # we are exiting Shift-* via TMS=1 on this very edge (the final bit
        # is part of the shifted value).
        in_shift = cur in (TapState.ShiftDR, TapState.ShiftIR)
        if in_shift:
            if self._buf_kind is None:
                self._buf_kind = "DR" if cur == TapState.ShiftDR else "IR"
                self._buf_entered_from = cur
                self._buf_first_offset = s.out_offset
            self._buf_tdi.append(s.tdi)
            self._buf_tdo.append(s.tdo)
            self._buf_last_offset = s.out_offset
            # Did we just exit Shift-*?
            exiting = nxt not in (TapState.ShiftDR, TapState.ShiftIR)
            if exiting:
                out.append(self._flush(exited_to=nxt))
        self.state = nxt

    def _flush(self, *, exited_to: TapState) -> ShiftEvent:
        assert self._buf_kind is not None
        length = len(self._buf_tdi)
        tdi = 0
        for i, b in enumerate(self._buf_tdi):
            tdi |= (b & 1) << i
        if any(t is None for t in self._buf_tdo):
            tdo: Optional[int] = None
        else:
            tdo = 0
            for i, b in enumerate(self._buf_tdo):
                tdo |= (b & 1) << i  # type: ignore[operator]
        ev = ShiftEvent(
            kind=self._buf_kind,
            length=length,
            tdi=tdi,
            tdo=tdo,
            entered_state=self._buf_entered_from,  # type: ignore[arg-type]
            exited_state=exited_to,
            byte_span=(
                self._buf_first_offset or 0,
                self._buf_last_offset or 0,
            ),
        )
        self._buf_tdi.clear()
        self._buf_tdo.clear()
        self._buf_kind = None
        self._buf_entered_from = None
        self._buf_first_offset = None
        self._buf_last_offset = None
        return ev


def decode_shifts(
    samples: Iterable[JtagSample],
    *,
    initial: TapState = TapState.TestLogicReset,
) -> list[ShiftEvent]:
    """Convenience: TAP-decode an entire sample stream in one call."""
    return TapDecoder(initial).feed(samples)
