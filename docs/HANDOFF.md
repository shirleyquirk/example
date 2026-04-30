# Handoff notes

Context I built up while writing the v0 decoder, captured here so picking
this back up on another machine doesn't lose it.

## Where things stand

- Spec, four layers of decoder, CLI, and 27 passing tests are committed
  and pushed on `claude/usb-blaster-decoder-PUu8O`.
- `vendor/jtag-remote-server` is wired in as a submodule — the encoder
  side of `src/usb_blaster.cpp` is treated as the golden producer for
  test fixtures. After cloning, run `git submodule update --init` before
  the tests will help you cross-reference the C source.
- The end-to-end test path validates layer 2-4 against a Python port of
  jtag-remote-server's encoder. Layer 1 (pcap → byte streams) has unit
  coverage only — see "real-hardware validation" below.

## Setup on a fresh machine

```
git clone <repo>
cd example
git submodule update --init
python -m venv .venv && source .venv/bin/activate
pip install -e '.[test]'
pytest
```

Should be 27 passes, sub-second total.

## Design decisions worth remembering

- **Layered, pure-function architecture.** Each of pcap_extract → blaster
  → jtag_bits → tap is a pure function of the previous layer's output.
  This is what makes the synthesised test path work: we can inject at
  layer 2 (raw blaster bytes) and skip the unvalidated pcap layer
  entirely. Don't collapse the boundaries.
- **No scapy / pyshark / dpkt dependency.** usbmon pcap is small enough
  that a custom struct parser pays for itself in fewer moving parts.
  Reconsider if we ever need PCAPng or USBPcap (Windows) support.
- **`tdo=None` when part of a shift had READ=0.** This is intentional —
  we genuinely don't know what TDO was for those cycles. The
  alternative (zero-fill) would silently lie about IDCODEs.
- **Shifts cross-merge across `scan_chain_send` calls without a TMS
  transition between them.** This is correct behaviour — the silicon
  sees one shift — but it bit me writing the e2e test. The assertion
  in `test_jtag_probe_devices_recovers_combined_dr_shift` documents
  this.
- **The exit bit is part of the shift.** When the TAP leaves Shift-* via
  TMS=1, the bit clocked on that edge is included in the shift's TDI/TDO.
  This matches jtag-remote-server's `flip_tms` convention and what
  silicon actually shifts in.

## Known unknowns

These are the things I'd want to confirm before claiming v1 done:

1. **FTDI bulk-IN status-byte behaviour at the pcap level.** Layer 1
   strips a 2-byte modem-status prefix from each 64-byte slice of every
   bulk-IN URB. That matches the FT245 datasheet, but I have not
   confirmed it against a real `jtagd` capture. Specifically:
     - Does the kernel's usbmon expose the raw IN buffer (including
       status bytes) or has the FTDI driver already stripped them by
       the time the URB completes?  My current code assumes raw.
     - When a single URB is larger than 64 bytes, does the device emit
       multiple FT245 packets each prefixed with two bytes, or one big
       buffer with two bytes total?  I currently assume per-64.
   Easiest fix path: capture a few seconds of `jtagd` traffic, look at
   one bulk-IN URB by hand, and adjust `_strip_ftdi_status` accordingly.
2. **OUT/IN ordering vs. URB completion timestamps.** I'm assuming
   submit-order on OUT and complete-order on IN gives a faithful
   pairing. If the FTDI driver issues out-of-order completions or if
   reads can race with subsequent writes this could break. Likely
   needs a real capture to test.
3. **Byte-shift LENGTH=63.** Spec says 1..63; jtag-remote-server caps at
   32. Have not seen 63 in the wild. Decoder accepts it; encoder helper
   accepts it. If real Quartus uses some other limit we'll find out.
4. **Bit-bang FTDI mode for chip-level reset.** Some drivers briefly
   switch the FTDI into asynchronous bitbang mode for `srst`. We
   currently assume MPSSE-style command bytes throughout. Real captures
   may show control transfers we need to recognise (SET_BITMODE 0x0B).

## Phase 2 — AJI client wrapper (in this branch)

We added `intel/libaji_client` as a submodule, built it from source, and
shipped a thin C++ shim + Python ctypes wrapper so we can drive `jtagd`
from Python. The whole point is round-trip validation: AJI op → USB pcap
→ our decoder → recovered IR/DR == what we asked for.

### Setup on the lab box

```sh
git submodule update --init --recursive

# Build libaji_client. The CET / Spectre flags conflict in modern gcc, so:
cd vendor/libaji_client
bash ./bootstrap
./configure --prefix="$PWD/_install"
make CXXFLAGS="-fcf-protection=none -O2 -g -Wno-error" \
     CFLAGS="-fcf-protection=none -O2 -g -Wno-error" -j

# Build the shim that flattens C++ overloads.
cd /path/to/example
make -C ext/aji_shim

# Install the Python package.
pip install -e '.[test]'

# Sanity-check (jtagd must be running):
aji-probe
```

### Capture-server hole in the bwrap

Setup recipe lives in `tools/capture-server/README.md`. Short version:
install `usb-blaster-capture.sh` to `/usr/local/bin`, give your user
NOPASSWD sudo on it, run `capture-server.py` outside the bwrap, bind
`/run/usb-blaster-decode` and `/var/lib/usb-blaster-decode` into the
sandbox.

### Running the hardware tests

```sh
USB_BLASTER_HW=1 \
USB_BLASTER_USBMON=usbmon0 \
USB_BLASTER_CAPTURE_SOCK=/run/usb-blaster-decode/capture.sock \
pytest tests/hw -v
```

`USB_BLASTER_HW=1` alone runs the wrapper smoke tests (no capture
needed); add `USB_BLASTER_CAPTURE_SOCK` for the round-trip tests.

### Phase 2 known unknowns

- **AJI flag sweeps.** `test_access_dr_flag_effect_on_wire` is set up
  with no assertions on purpose — it's a corpus-builder. Run it once on
  hardware with `pytest -s`, eyeball the wire-level output for each
  flag, and write down what each does in `docs/usb-blaster-protocol.md`
  or a new `docs/aji-flags.md`.
- **AJI claim semantics.** The smoke tests use a weak `IR_WEAK ~0`
  claim, which is what you want for ad-hoc decoder tests but not for
  production code. If `aji_open_device` returns `INSTRUCTION_CLAIMED`,
  another client (Quartus Programmer, Signal Tap) is holding a stronger
  claim — kill it before testing.
- **`aji_access_ir` with `instruction_length > 32`.** The DWORD-form
  overload only fits 32 bits; longer IRs need the bit-vector form.
  `OpenDevice.access_ir_bits` is wired up but untested against silicon.
- **`aji_open_entire_device_chain`.** Not wrapped. We'd need it for
  testing daisy-chained devices.
- **The capture-server's tshark stop semantics.** SIGTERM should let
  tshark flush, but on some kernels the last few packets can be lost in
  the kernel ring buffer. If we see truncated pcaps, switch to
  `SIGINT` + a small grace period.

## Roadmap / next steps after phase 2

In rough order of value:

1. **Use the round-trip harness to characterise AJI's flag effects.**
   Build a table: `(IR or DR) × flags × jtagd version → on-the-wire
   shape`. This is the corpus we need before decoding `jtagd`-driven
   captures becomes reliable.
2. **Layer 5 starting with IDCODE decoding.** Pattern-match 32-bit DR
   shifts that follow IR=IDCODE or come straight out of TLR-induced
   auto-load and display manufacturer / part number. JEDEC manufacturer
   IDs are well-known.
3. **Altera virtual JTAG / SLD hub.** This is the big payoff for
   reverse-engineering Quartus traces. Cross-reference with urjtag's
   `data/altera/jtag` and the SLD hub docs.
4. **Optional Wireshark Lua dissector.** Once layer 4 is solid we can
   wrap it as a Lua dissector for usb.capdata. Lua is the supported
   path; Wireshark Python is fragile.

## Pointers into the vendor submodule

Most useful files when you need to remember what the protocol does:

- `vendor/jtag-remote-server/src/usb_blaster.cpp:16` — `build_command`,
  the canonical bit-bang byte format.
- `vendor/jtag-remote-server/src/usb_blaster.cpp:114` — `scan_chain_send`,
  shows MAX_PACKET_SIZE=32 chunking and the 8-bit-tail bit-bang fallback.
- `vendor/jtag-remote-server/src/common.cpp:9` — `next_state`, the TAP
  transition table the layer-4 decoder mirrors.
- `vendor/jtag-remote-server/src/common.cpp:330` — `jtag_probe_devices`,
  the canonical "how do I find IDCODEs" sequence we should be able to
  decode end-to-end.

## Things I considered and dropped

- **scapy/pyshark for layer 1.** Both pull in big dependency trees and
  add little. usbmon header is ~48 bytes of well-documented struct.
- **dpkt.** Same reasoning — one extra dep for a few struct.unpack
  calls.
- **PCAPng.** Modern Wireshark writes pcapng by default. We only handle
  classic pcap right now. If `tshark -F pcap` is too painful for users
  we'll need to add pcapng support; not hard but not free.
- **Streaming layer 4 decode from a live USB feed.** Out of scope for
  v1; the layered architecture leaves room.
