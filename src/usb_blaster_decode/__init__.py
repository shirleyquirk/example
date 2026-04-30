"""Decode captured USB traffic from an Altera USB Blaster into JTAG shifts.

The pipeline is layered (see ``docs/usb-blaster-protocol.md``):

    pcap_extract  -> blaster  -> jtag_bits  -> tap

Each layer is a pure function over the previous layer's output, so each can
be unit-tested in isolation and synthesised fixtures can be injected at any
boundary.
"""

from .blaster import BlasterEvent, parse_blaster_stream
from .jtag_bits import JtagSample, samples_from_blaster_events
from .tap import ShiftEvent, TapDecoder, TapState

__all__ = [
    "BlasterEvent",
    "parse_blaster_stream",
    "JtagSample",
    "samples_from_blaster_events",
    "ShiftEvent",
    "TapDecoder",
    "TapState",
]
