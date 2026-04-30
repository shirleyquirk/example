"""``aji-probe`` — sanity-check the wrapper against a running jtagd.

Lists discovered cables and the device chain on each. Useful to verify
the shim is loading and jtagd is reachable before running the round-trip
tests.
"""

from __future__ import annotations

import argparse
import sys

from .client import AjiClient
from .errors import AjiError


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="aji-probe")
    p.add_argument("--cable", help="select a specific cable by hw_name or persistent_id")
    args = p.parse_args(argv)

    aji = AjiClient()
    try:
        cables = aji.get_hardware()
    except AjiError as e:
        print(f"aji_get_hardware failed: {e}", file=sys.stderr)
        return 1

    if not cables:
        print("No JTAG hardware found by jtagd")
        return 1

    cables_to_show = (
        [c for c in cables if args.cable in (c.hw_name, str(c.persistent_id))]
        if args.cable
        else cables
    )
    for c in cables_to_show:
        print(
            f"cable {c.hw_name!r} pid={c.persistent_id} port={c.port!r} "
            f"server={c.server!r} features=0x{c.features:04x}"
        )
        try:
            chain = aji.read_device_chain(c)
        except AjiError as e:
            print(f"  (chain read failed: {e})")
            continue
        for d in chain:
            print(
                f"  tap{d.tap_position}: idcode=0x{d.device_id:08x} "
                f"ir_len={d.instruction_length} {d.device_name!r}"
            )
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
