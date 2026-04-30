"""CLI: ``usb-blaster-decode <pcap>`` prints a summary of IR/DR shifts."""

from __future__ import annotations

import argparse
import sys

from .blaster import parse_blaster_stream
from .jtag_bits import samples_from_blaster_events
from .pcap_extract import extract_streams
from .tap import TapState, decode_shifts


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        prog="usb-blaster-decode",
        description="Decode an Altera USB Blaster pcap into JTAG IR/DR shifts.",
    )
    p.add_argument("pcap", help="path to a usbmon pcap file")
    p.add_argument("--bus", type=int, help="USB bus number to filter on")
    p.add_argument("--device", type=int, help="USB device number to filter on")
    p.add_argument(
        "--lenient",
        action="store_true",
        help="don't raise on truncated/short streams",
    )
    args = p.parse_args(argv)

    streams = extract_streams(args.pcap, bus=args.bus, device=args.device)
    print(
        f"# bus={streams.bus} dev={streams.device} "
        f"out_ep={streams.out_endpoint} in_ep={streams.in_endpoint} "
        f"out_bytes={len(streams.out_bytes)} in_bytes={len(streams.in_bytes)}"
    )
    events = parse_blaster_stream(
        streams.out_bytes, streams.in_bytes, strict=not args.lenient
    )
    samples = samples_from_blaster_events(events)
    shifts = decode_shifts(samples, initial=TapState.TestLogicReset)
    for s in shifts:
        tdo = s.tdo_hex() if s.tdo is not None else "-"
        print(
            f"{s.kind} len={s.length:<4d} "
            f"tdi={s.tdi_hex():>20s} tdo={tdo:>20s} "
            f"out_offsets={s.byte_span[0]}..{s.byte_span[1]} "
            f"({s.entered_state.name} -> {s.exited_state.name})"
        )
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
