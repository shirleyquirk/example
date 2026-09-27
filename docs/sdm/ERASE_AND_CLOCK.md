# Erase block size and JTAG clock: investigation

**Tags:** **[src]** = read in source code. **[ds]** = flash datasheet figures, from memory: check
them against your exact part. **[?]** = speculation, measure before relying on it.

## 1. Why erase size is the lever

Typical figures for Micron MT25Q, the flash on most Agilex boards **[ds]**:

| Operation | Typical | Max | Time for 1 MiB |
|---|---|---|---|
| 4 KiB subsector erase | ~50 ms | ~400 ms | 256 × 50 ms ≈ **12.8 s** |
| 32 KiB subsector erase | ~100 ms | ~1 s | 32 × 100 ms ≈ **3.2 s** |
| 64 KiB sector erase | ~150 ms | ~1 s | 16 × 150 ms ≈ **2.4 s** |
| 256 B page program | ~0.12 ms | ~1.8 ms | 4096 × 0.12 ms ≈ **0.5 s** |

Erase time dominates program time: about 25× at 4 KiB granularity and still about 5× at 64 KiB.
So the order of wins is:
1. Don't erase at all.
2. Erase with the biggest block.
3. Everything else (JTAG clock, chunk size, round trips).

## 2. What the SDM does today

- `QSPI_ERASE` takes `{addr, nwords}` at 4 KiB granularity **[src: ATF]**. Which flash opcode
  the SDM issues is not documented.
- `QSPI_GET_DEVICE_INFO` returns **4 × {size, erasesize}**, one pair per chip select
  **[src: U-Boot `rsu_ll_qspi.c`, Linux `stratix10-rsu.c`]**. The `size` field uses the **SFDP**
  density encoding: bit 31 = 0 means a bit count, bit 31 = 1 means 2^N bits. SFDP is the JEDEC
  standard table in which a flash describes itself, including its supported erase types
  (size + opcode). The SDM therefore very likely reads SFDP and picks **one** erase size, which it
  reports as `erasesize` **[?]**.
- Because the command accepts 4 KiB-aligned ranges, the SDM must use 4 KiB erases at least at
  unaligned edges. It might use 4 KiB throughout. That would be the slow case: 5× slower per byte
  than 64 KiB **[?]**.

The `erase_sweep` probe settles this: it erases 256 KiB with `QSPI_ERASE` at 4K/32K/64K/256K per
command. If time scales with bytes regardless of command size, the SDM is using small erases
internally.

## 3. Ways to choose the erase size, ranked

| # | Method | Control | Status |
|---|---|---|---|
| 1 | **Skip the erase** (`--write-first`): program, verify, and erase + rewrite only spans that fail. Fresh flash comes from the factory erased. | total | Implemented and tested on the fake |
| 2 | **Direct opcodes** (`--erase-method direct`): `SEND_DEVICE_OP 0x06` (write enable), `WRITE_DEVICE_REG` with the erase opcode and the address MSB first (Intel documents this use), then poll status register bit 0 (write in progress) via `READ_DEVICE_REG 0x05`. | per operation: 4K `0x21`, 32K `0x5C`, 64K `0xDC` (4-byte address forms; 3-byte forms for flash ≤ 16 MiB) | Implemented, HIL probe `direct_erase_64k` + `erase_sweep_direct` |
| 3 | **Greedy mixed sizes** (`--erase-sizes 64K,32K,4K`): at each address use the largest block that is aligned and fits. You get 64K speed in the middle and 4K precision at the edges. | planner | Implemented; works with both erase methods |
| 4 | **Larger `QSPI_ERASE` commands** (`--erase-cmd-max`): only helps if the SDM already uses big opcodes when it can | SDM's choice | Knob exists; `erase_sweep` answers it |
| 5 | **Flash-side configuration**: some parts change their sector layout, and with it what SFDP advertises (Infineon S25FS-S/S25FL-S "uniform 256 KiB, 4 KiB erase disabled" via non-volatile config; SEMPER hybrid/uniform). MT25Q and MX25/66 have fixed layouts where every size is always available. | changes what the SDM sees | Not done. It is a non-volatile, boot-affecting change, so last resort. |
| 6 | **Chip/die erase** (`0xC7`/`0x60`, Micron die erase `0xC4`) | whole device | Supported by the fake, not by the writer. Per byte it is about the same rate as 64 KiB erase on MT25Q **[ds]**, so it only wins if command overhead dominates. |

**Risks and caveats:**
- **Direct opcodes:** the SDM might refuse or filter them, might not send write-enable itself
  (we send it anyway), and might hold the flash in a different address mode. The 4-byte opcodes
  avoid depending on the address mode. `direct_erase_64k` is the go/no-go test.
- **Write-first:** only safe on plain NOR, where programming only clears bits and verify catches
  any bit that needed to go back to 1. Flash with internal ECC that forbids re-programming a page
  (Infineon SEMPER, some Macronix ECC parts) must not use it. It also leaves bytes in a span that
  no file covers untouched, where the erase path would have wiped them. For factory bring-up
  that's arguably better.
- Erasing at 64 KiB widens the collateral erase at file edges. The planner warns about it, and
  greedy mixed sizes remove it.

**Expected effect on a 64 MiB image, typical figures:** 4K erase + program ≈ 64 × (12.8 + 0.5) s
≈ 14 min. 64K erase ≈ 64 × 2.9 s ≈ 3 min. Write-first on blank flash ≈ 64 × 0.5 s ≈ 32 s plus
the verify readback. These numbers only show how much is at stake; the probes produce the real ones.

## 4. JTAG clock (`jtagconfig --setparam <cable> JtagClock <freq>`)

**Mechanism [src: intel/libaji_client].** jtagconfig is a jtagd client. Setting a cable
parameter is one AJI message, `SET_PARAMETER` (0xAA), carrying `{chain_id, name, DWORD value}`.
The API is:

```cpp
aji_lock_chain(chain, timeout_ms);                     // required: AJI_NOT_LOCKED otherwise
aji_get_parameter(chain, "JtagClock", &before);
aji_set_parameter(chain, "JtagClock", hz);
aji_unlock_chain(chain);
```

It is implemented as `sdm::jtag::setJtagClock(chain, hz)` in `sdm/include/sdm/jtag_clock.hpp`.
It compiles only when `aji.h` is available. It type-checks against Intel's `aji.h` via
`-DSDM_AJI_INCLUDE_DIR=…/libaji_client/src/h`. The fallback is
`setJtagClockViaJtagconfig(cable, hz)`, and the CLI has `--jtag-clock 16M --cable 1`.

**Unknowns [?]:**
- **Units.** The value is assumed to be Hz. `setJtagClock` returns the value read before and
  after, so the first bench run settles it (expect 24000000 on a USB-Blaster II).
- **Persistence.** The setting probably lasts until jtagd restarts or the cable is replugged, so
  set it on every run.
- **Lock.** If SdmService holds the chain lock for its whole lifetime, call `aji_set_parameter`
  under that lock, through a hook in SdmService, instead of from outside.
- **Supported values.** USB-Blaster (I) is fixed at about 6 MHz and has no `JtagClock` parameter.
  USB-Blaster II accepts a small set (6M/16M/24M are the usual ones). For Blaster III and
  third-party cables, check `jtagconfig --getparam`.

**Will it help? [?]** A 4 KiB `QSPI_WRITE` is about 33 Kbit of payload: about 5.5 ms at 6 MHz
and 1.4 ms at 24 MHz, against about 2 ms of page programming. Each command also needs several
jtagd/USB round trips (send, poll, read), each roughly 0.1–1 ms. So the clock matters at 6 MHz,
is about break-even at 24 MHz, and past that latency dominates. At that point bigger commands
(`max_words`) and fewer round trips are the lever, not TCK. The `clock_sweep` probe
(`hil::Config::setJtagClock`) measures NOOP latency, write MB/s and read MB/s at each frequency.

## 5. Probes that answer this (`hil::characterise`)

| Probe | Answers |
|---|---|
| `device_info` | Raw `{size, erasesize}` per chip select: what erase size the SDM believes in |
| `erase_sweep` | Does `QSPI_ERASE` get faster per byte with bigger commands? |
| `erase_sweep_direct` | 4K/32K/64K opcode timings and WIP poll counts: the real flash numbers |
| `direct_erase_64k` (assertion) | Go/no-go for direct opcodes through the SDM |
| `clock_sweep` | Throughput against TCK: is the link clock-bound or latency-bound? |
| `latency_floor`, `max_words_read` | Per-command overhead and the biggest command, for the round-trip side |
