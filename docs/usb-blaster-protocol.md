# Altera USB Blaster protocol — decoder reference

This document is the working spec for the decoder in this repo. It is built
from three sources cross-referenced against each other:

1. The ixo-jtag write-up at
   <https://ixo-jtag.sourceforge.net/archive/ixo_de_usb_jtag.html>
2. OpenOCD's `src/jtag/drivers/usb_blaster/usb_blaster.c`
3. `vendor/jtag-remote-server/src/usb_blaster.cpp` (treated as the golden
   producer for our test fixtures, see `tests/`)

Where the three disagree, the disagreement is called out inline.

---

## 1. Transport — USB / FTDI

The original Altera USB Blaster and the common ixo/ftdi clones expose an
FTDI FT245BM-style bulk pipe:

- VID/PID: `09fb:6001` (and clones such as `09fb:6002`, `09fb:6003`).
- Two bulk endpoints: one OUT (host → device, command bytes), one IN
  (device → host, TDO replies).
- Control transfers configure the FTDI side: baud rate (ignored by the
  blaster firmware but commonly set to 115200), latency timer
  (jtag-remote-server sets it to 1 ms), and bitbang/reset commands.
  These are not part of the JTAG protocol and the decoder treats them as
  out-of-band: it skips them but records their presence.

### 1.1 FTDI bulk IN framing

Every bulk-IN transfer the FTDI chip emits is prefixed with **two modem-status
bytes** (`0x31 0x60` in the steady state). Those bytes are not blaster TDO
data and must be stripped before feeding the IN stream to layer 2. If a single
URB contains multiple FTDI USB packets (size > wMaxPacketSize, typically 64
bytes), each 64-byte slice carries its own 2-byte header.

> Status: layer 1 strips the headers, but the exact behaviour under bulk
> read coalescing is something we need to confirm against a real capture.
> The jtag-remote-server fixture path bypasses layer 1 entirely.

---

## 2. Layer 2 — USB Blaster command bytes

The blaster firmware has two encodings on the OUT pipe. The high bit of each
byte selects which.

### 2.1 Bit-bang byte (bit 7 = 0)

| bit | name  | meaning                                                |
|----:|-------|--------------------------------------------------------|
| 0   | TCK   | drives TCK pin                                         |
| 1   | TMS   | drives TMS pin                                         |
| 2   | nCE   | (legacy ByteBlaster); drivers force it high            |
| 3   | nCS   | (legacy ByteBlaster); drivers force it high            |
| 4   | TDI   | drives TDI pin                                         |
| 5   | LED   | front-panel LED; drivers force it high                 |
| 6   | READ  | if set, sample TDO and queue 1 byte to the IN pipe     |
| 7   | SHIFT | 0 = bit-bang byte (this format), 1 = byte-shift header |

A bit-bang byte directly latches all four JTAG outputs. The convention every
driver follows is to emit pairs of bytes per JTAG bit: TCK=0 then TCK=1, with
TMS/TDI held stable across the pair. The READ bit, when set, is set on the
TCK=1 byte so TDO is sampled on the rising edge.

### 2.2 Byte-shift header (bit 7 = 1)

| bit  | name   | meaning                              |
|-----:|--------|--------------------------------------|
| 7    | SHIFT  | 1                                    |
| 6    | READ   | if set, IN pipe gets N reply bytes   |
| 5..0 | LENGTH | N = number of data bytes that follow, 1..63 |

The header is followed by `N` data bytes. The blaster clocks out
`8N` TDI bits, **LSB-first per byte**, with TMS held at 0 and TCK toggling
internally. If READ=1 the device returns `N` reply bytes on the IN pipe; bit
i of reply byte b is the TDO sample taken at the rising edge that shifted out
TDI bit i of data byte b. nCE/nCS/LED are held at their last bit-bang values.

LENGTH=0 is reserved (firmware-dependent; treat as a decode error). OpenOCD
caps writes at 63; jtag-remote-server self-limits to 32 per transfer.

### 2.3 IN pipe

The IN pipe carries one reply byte per READ-flagged sample, in the order they
were requested:

- one byte per READ-flagged bit-bang byte (only bit 0 of each reply is
  meaningful; the other bits are firmware noise and must be masked off);
- `N` bytes per byte-shift header with READ=1, full bytes are meaningful
  TDO samples, LSB-first matching the corresponding TDI bytes.

Because writes are queued, the IN stream does not arrive synchronously with
its OUT bytes. The decoder must reassemble both pipes in time order and pair
each READ request to the next available IN byte(s).

---

## 3. Layer 3 — JTAG bits from blaster bytes

Layer 3 collapses the layer-2 byte stream into a stream of `(TMS, TDI, TDO?)`
samples, one per logical TCK rising edge:

- For bit-bang: a TCK 0→1 transition between two consecutive bit-bang bytes
  with the same TMS/TDI is a sample. The TDO field is filled from the IN
  pipe iff the TCK=1 byte had READ set.
- For byte-shift: each data byte expands to 8 samples with TMS=0; TDI bits
  come from the byte LSB-first; TDO bits, if READ was set, come from the
  paired IN byte LSB-first.

Bit-bang bytes that are not part of a TCK 0→1 pair (e.g. the trailing TCK=0
byte that drivers emit to leave TCK low) generate no sample.

---

## 4. Layer 4 — TAP state machine and IR/DR shifts

Layer 4 walks the IEEE 1149.1 TAP state machine over the layer-3 sample
stream and emits a shift event each time the TAP exits Shift-IR or Shift-DR.

A shift event carries:

- `kind`: `IR` or `DR`
- `length`: number of bits shifted in Shift-* (the bit clocked out as the
  state leaves Shift-* via TMS=1 is included — this is how real JTAG works,
  and it matches the `flip_tms` convention in jtag-remote-server)
- `tdi`: integer of length bits, LSB = first bit shifted (matches blaster
  byte-shift order so `hex(tdi)` reads naturally for byte-aligned shifts)
- `tdo`: same shape as `tdi`, or `None` if READ was off for any sample in
  the shift
- `entered_state`, `exited_state`: TAP state on the cycle the first/last
  bit was sampled
- `byte_offsets`: span in the layer-2 byte stream this shift came from
  (useful for cross-referencing with Wireshark)

The TAP transition table is the standard one (see
`vendor/jtag-remote-server/src/common.cpp:9-47` for a compact reference).

---

## 5. What this decoder does *not* do (yet)

- **Layer 5 (instruction decoding).** No IDCODE → device-name lookup, no
  Altera virtual-JTAG / SLD-hub decoding. The shift events are raw.
- **Bit-bang FTDI mode.** The blaster sometimes gets put into FTDI bitbang
  mode for chip-level reset; that path is currently ignored.
- **Multiple chained blasters.** Only one blaster on one USB device is
  decoded per pcap.
- **Real hardware validation.** Layers 2-4 are exercised end-to-end against
  a Python re-implementation of jtag-remote-server's encoding logic. Layer
  1 (pcap → OUT/IN streams) is exercised against a synthesised pcap and
  will need a real-hardware capture before we can claim it works against
  Quartus / `jtagd`.
