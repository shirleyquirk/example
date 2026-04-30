"""Layer 3: convert blaster events into JTAG samples (one per TCK rising edge).

A sample is the canonical (TMS, TDI, TDO?) tuple that the TAP state machine
in layer 4 consumes. We give each sample a back-reference to the layer-2
byte offset that produced it so downstream errors can point into the OUT
stream (and ultimately into the original pcap).
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable, Optional

from .blaster import BitBangEvent, BlasterEvent, ByteShiftEvent


@dataclass(frozen=True)
class JtagSample:
    tms: int
    tdi: int
    tdo: Optional[int]   # None if READ was not set on the byte that sampled
    out_offset: int      # offset in the OUT byte stream that produced this


def samples_from_blaster_events(
    events: Iterable[BlasterEvent],
) -> list[JtagSample]:
    """Reduce a sequence of blaster events to per-TCK-edge JTAG samples.

    Bit-bang pairs are detected by looking for a TCK 0->1 transition between
    two consecutive bit-bang bytes that share TMS and TDI. Bytes that don't
    participate in such a pair (a leading TCK=0, a trailing TCK=0 to leave
    TCK low, idle pulses on a stable TMS/TDI without a 0->1 edge) emit no
    sample. This matches the convention every driver follows and is what
    jtag-remote-server's bit-bang path produces.
    """
    samples: list[JtagSample] = []
    prev: Optional[BitBangEvent] = None
    for ev in events:
        if isinstance(ev, ByteShiftEvent):
            # Byte-shift: 8 samples per data byte, TMS=0, LSB-first.
            for byte_idx, tdi_byte in enumerate(ev.tdi):
                tdo_byte = ev.tdo[byte_idx] if ev.tdo is not None else None
                for bit_idx in range(8):
                    samples.append(
                        JtagSample(
                            tms=0,
                            tdi=(tdi_byte >> bit_idx) & 1,
                            tdo=(
                                (tdo_byte >> bit_idx) & 1
                                if tdo_byte is not None
                                else None
                            ),
                            out_offset=ev.offset,
                        )
                    )
            prev = None
            continue

        # bit-bang
        if (
            prev is not None
            and prev.tck == 0
            and ev.tck == 1
            and prev.tms == ev.tms
            and prev.tdi == ev.tdi
        ):
            samples.append(
                JtagSample(
                    tms=ev.tms,
                    tdi=ev.tdi,
                    tdo=ev.tdo,  # READ is set on the rising-edge byte
                    out_offset=ev.offset,
                )
            )
            prev = None
        else:
            prev = ev
    return samples
