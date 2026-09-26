# SDM service: test suite and manufacturing flash writer roadmap

Goals:

- **(a)** A test suite that exercises every known SDM QSPI command (and the generic status
  commands) through the existing templated `SdmService`.
- **(b)** A motivating example: write a folder of `.bin` files to QSPI at offsets taken from
  their filenames, replacing `quartus_pgm`/`quartus_jli` in manufacturing.

Protocol details and sources are in [PROTOCOL.md](PROTOCOL.md).

---

## 0. Decisions and open inputs

| Topic | Status |
|---|---|
| Transport | **jtagd.** The same path as `quartus_pgm`/`quartus_jli`, so no difference in cable speed. The win is not paying Quartus' per-invocation startup, plus doing less work (skipping blank chunks, choosing the erase size). |
| Service API | `sdm.sendCommand<Command::X>(args?)` returns a `Response`, and `Response.code()` gives the SDM error code. Two **assumptions** remain, both isolated in `sdm/include/sdm/adapter.hpp`: args arrive as `std::span<const uint32_t>`, and `Response.data()` gives the payload words. Fix them there if they are wrong. |
| Filename → offset | **Placeholder**: `placeholderOffsetParser` takes the first `0x<hex>` token. This is swappable because `loadDirectory` takes an `OffsetParser`. |
| Erase block size | **A knob, to be swept.** `PlanOptions::eraseBlock` (alignment/rounding) and `maxEraseBytesPerCmd` (bytes per `QSPI_ERASE`), exposed as `--erase-block` and `--erase-cmd-max`. The `erase_sweep` probe times 4K/32K/64K/256K on hardware. |
| Test framework | doctest (vendored, single header). No preference was given, so switching is cheap. |
| `SdmService` source | Still not in the repo. The command diff table (§1) waits on its enum. |

## 1. Command completeness check

Output: a table with one row per command code (PROTOCOL.md §3), in three columns:
*in SdmService? / has typed wrapper? / has test?*

Priority set (must have typed wrappers):
`NOOP, CONFIG_STATUS, RECONFIG_STATUS, GET_IDCODE, GET_CHIPID, GET_USERCODE,
QSPI_OPEN, QSPI_CLOSE, QSPI_SET_CS, QSPI_READ_DEVICE_REG, QSPI_WRITE_DEVICE_REG,
QSPI_SEND_DEVICE_OP, QSPI_ERASE, QSPI_WRITE, QSPI_READ, QSPI_GET_DEVICE_INFO,
GET_SUBPARTITION_TABLE, RSU_STATUS`.

Everything else is reachable through a raw `send(code, args)` escape hatch and gets no
wrapper until something needs it.

## 2. Test suite (a)

Three layers. Each layer lets the next one assume less.

### L0: pure encoding (no hardware, CI)
- Header encode/decode round-trips, with golden vectors built from the ATF macros
  (`MBOX_FRAME_CMD_HEADER`, `MBOX_RESP_ERR/LEN/JOB_ID`).
- Argument packing for each typed wrapper, for example `QSPI_SET_CS(cs=1, mode=0, ca=0)` → `0x10000000`.
- Host-side argument validation: erase address not 4 KiB aligned; erase `nwords % 0x400 != 0`;
  write address not word aligned; `nwords > MAX`. These must fail **before** anything goes
  on the wire.
- Error-code decode: every code in PROTOCOL.md §2 maps to a named enum and a message.

### L1: fake SDM (no hardware, CI)
A `FakeSdm` transport that plugs into the template parameter. It models:
- A flash array. Erase sets bytes to `0xFF`; program is `old & new`, like real NOR, so a
  missing erase gives corrupted data rather than a silent pass.
- The QSPI ownership state machine: OPEN, CLOSE, commands before OPEN, double OPEN.
- Configurable limits: `MAX_WORDS`, flash size, erase granularity.
- **Fault injection:** fail the Nth command with code X, drop a response, return a wrong
  job ID, return a short response, or simulate a cable disconnect. The error-handling code
  gets exercised here long before hardware is involved.
- A timing model (per-command latency, erase ms/KiB) so the writer's scheduler can be tuned
  without a board.

The flash-writer example (§3) runs end to end against `FakeSdm` in CI.

### L2: hardware in the loop (opt-in: `SDM_HIL=1`, `SDM_CABLE=…`, `SDM_SCRATCH=0x…`)
Every test touches only a **scratch region** named in the environment. Tests are split into:

**Assertions** (stable, pass/fail):
| Test | Commands |
|---|---|
| identity | GET_IDCODE, GET_CHIPID, GET_USERCODE; IDCODE matches the expected family |
| status | CONFIG_STATUS, RECONFIG_STATUS; state is user mode, CONF_DONE and INIT_DONE set |
| qspi_session | OPEN → SET_CS(0) → CLOSE; OPEN → CLOSE → OPEN (re-open works) |
| jedec | READ_DEVICE_REG(0x9F, 3) returns a non-0xFFFFFF and non-0 ID that is stable across calls |
| device_info | GET_DEVICE_INFO decodes to a size that matches the JEDEC density byte |
| erase_read | ERASE 4 KiB → READ is all 0xFF |
| write_read | ERASE → WRITE pattern → READ matches, at 1 word, 64 words, MAX words |
| status_reg | SEND_DEVICE_OP(0x06 WREN) → READ_DEVICE_REG(0x05) has WEL set → SEND_DEVICE_OP(0x04 WRDI) clears it |
| boundary_16M | write/read across `0x00FFFFF0..0x01000010` (the 3-byte/4-byte addressing trap) |
| close_on_throw | RAII guard sends QSPI_CLOSE when the scope unwinds from an exception |

**Characterisations** (record and report, never fail). Each writes a JSON line to
`sdm_characterisation.jsonl`, and these files become the failure-mode catalogue:
| Probe | Question it answers |
|---|---|
| max_words | Binary search for the largest QSPI_WRITE/READ `nwords` accepted over JTAG, and the error code above it (ATF says 4096 words, the IP UG says 1024) |
| latency_floor | NOOP round-trip distribution (p50/p99). This is the per-command overhead. |
| write_throughput | MB/s against chunk size (256 B … MAX) |
| erase_timing | ERASE 4 KiB / 32 KiB / 64 KiB / 1 MiB: does the SDM block until done, how long it takes, and whether 64 KiB counts as one sector erase or 16 subsector erases |
| err_unaligned | error code for misaligned erase/write |
| err_oversize | error code for `nwords > MAX` |
| err_past_end | error code past the end of flash (KB 343452 says it is wrong, so record what we actually get) |
| err_no_open | QSPI_WRITE without OPEN |
| err_double_open | OPEN twice, and OPEN from a second process |
| err_stale_open | kill the process after OPEN, then find what the next session sees and what recovers it (CLOSE? RESTART? reconfig?) |
| err_no_helper | every QSPI command with the device unconfigured |
| err_direct | QSPI_DIRECT from JTAG |
| write_unerased | WRITE over non-erased data: does the SDM refuse, or silently AND the bits? |
| cable_yank | (manual) pull the cable mid-write: which layer reports what? |

## 3. Motivating example (b): `sdm-flash`

```
sdm-flash [--cable N] [--device N] [--no-verify] [--dry-run] <dir>
```

### Design

1. **Plan (pure, host-only, unit-tested).**
   `FlashPlan::from_dir(dir)`: parse offsets, sort, and reject overlaps. Build a *sparse image
   map* (sorted extents), then derive
   - erase spans: the union of extents rounded out to 4 KiB, merged. This stops two files
     that share a 4 KiB block from erasing each other's data. If rounding out would erase
     bytes that belong to no file, warn, because those bytes are lost.
   - write chunks: at most `MAX_WORDS` each, word aligned. The tail is padded with `0xFF`,
     and all-`0xFF` chunks are skipped since erase already left them `0xFF`.
   - `--dry-run` prints this plan and exits.

2. **Execute** (the typed API the example should make look obvious):
   ```cpp
   auto sdm   = SdmService<Transport>{cable, device};
   auto id    = sdm.get_idcode();                 // log it
   auto qspi  = sdm.qspi_session(/*cs=*/0);       // RAII: OPEN+SET_CS / CLOSE
   auto info  = qspi.device_info();
   plan.check_fits(info);
   for (auto& e : plan.erases())  qspi.erase(e.addr, e.len);
   for (auto& w : plan.writes())  qspi.write(w.addr, w.data);
   if (verify) for (auto& w : plan.writes()) qspi.verify(w.addr, w.data);
   ```
   `qspi_session` is the only way to reach QSPI commands, so forgetting CLOSE is impossible
   by construction.

3. **Report.** Per file: bytes, erase ms, write ms, verify ms, MB/s. Per command: count and
   p50/p99 latency. Every error names the file, flash address, command, args summary, SDM
   code and name, and the attempt number.

### Error handling, phase 1 (optimistic)
- The first failure stops the run. The report shows everything that completed, the failing
  command in full, and the flash range that is now in an unknown state.
- No retries. Retrying before the failure modes are known hides them.
- `QSPI_CLOSE` is still sent (RAII) unless the transport itself is dead.

### Error handling, phase 2 (after the L2 characterisation data exists)
Classify errors into `Transport | Protocol | Sdm(code) | Verify` and pick a policy per class
from the data. For example: a transient transport error means reconnect and resume from the
last verified chunk; a stale ownership error means CLOSE and re-OPEN once; a verify mismatch
means re-erase the block and rewrite it once, then fail hard.

### Speed: expectations and unconventional options
The flash, not JTAG, bounds throughput. NOR page program is roughly 0.2–1 ms per 256 B, and
sector erase is roughly 0.1–0.5 s per 64 KiB. At 24 MHz TCK a 16 KiB payload is about 5 ms
of raw shifting. So matching Quartus should be easy once jtagd and quartus startup are gone.
Real gains beyond that come from doing less work:

1. **Skip `0xFF` chunks** (padding in images can be large). Free.
2. **Erase at the largest granularity the SDM will use.** Depends on what `erase_timing` shows.
3. **Speculative:** for full-flash writes, a chip erase (`QSPI_SEND_DEVICE_OP 0xC7` after WREN,
   then poll `READ_DEVICE_REG 0x05` WIP) could replace thousands of sector erases, if the SDM
   allows raw opcodes like that and does not time out. Test it on a scratch board first.
4. **Verify cheaply:** read back only on the first N boards of a batch, or skip readback and
   trust `RSU_STATUS`/`GET_SUBPARTITION_TABLE` plus a boot test. That is a policy decision
   for mfg, not a technical one.
5. **Program several boards in parallel:** one process per cable. Without Quartus'
   per-invocation cost this scales almost linearly.
6. **Speculative:** pipeline commands with job IDs (send write N+1 before response N). The
   JTAG packet path may be strictly request/response. Measure `latency_floor` first; this is
   only worth doing if the floor is a large share of per-chunk time.

## 4. Milestones

| # | Deliverable | Needs HW | Exit criterion |
|---|---|---|---|
| M0 | `SdmService` in repo; command diff table (§1) filled in | no | every PROTOCOL.md code has a row. **Open** |
| M1 | L0 tests + typed QSPI wrappers + `QspiSession` RAII | no | **Done** against the stand-in `sdm::Command` |
| M2 | `FakeSdm` + L1 tests incl. fault injection | no | **Done** |
| M3 | `FlashPlan` + `sdm-flash --dry-run` / `--fake` | no | **Done**, including shared-block, overlap, blank-skip and erase-knob cases |
| M4 | L2 assertions on a real Agilex 7 board | yes | all pass on 1 board |
| M5 | L2 characterisations → `sdm_characterisation.jsonl`; PROTOCOL.md `[?]` items resolved | yes | MAX_WORDS, erase semantics, stale-open recovery known |
| M6 | `sdm-flash` optimistic, real flash of a mfg image set; timing against `quartus_pgm -o pvi` | yes | byte-identical readback, time ≤ Quartus |
| M7 | Phase-2 error policies from M5 data; parallel multi-board | yes | defined behaviour for every catalogued failure |

## 5. Code map

| Path | What |
|---|---|
| `sdm/include/sdm/adapter.hpp` | **The only file that knows SdmService's shape.** `SdmServiceLike` concept, `send<C>()`, `words()` |
| `sdm/include/sdm/command.hpp` | Stand-in command enum (replace with SdmService's own) |
| `sdm/include/sdm/error.hpp` | SDM error-code names, `SdmError`, `UsageError` |
| `sdm/include/sdm/qspi.hpp` | `QspiSession<Sdm>`: RAII open/close, checked erase/write/read/device-reg ops, raw escape hatch |
| `sdm/include/sdm/flash_plan.hpp`, `src/flash_plan.cpp` | Directory → images → erase spans and write chunks |
| `sdm/include/sdm/flash_writer.hpp` | `writeFlash<Sdm>()`: execute a plan, verify, report, phase-1 error policy |
| `sdm/testing/fake_sdm.hpp` | NOR-accurate fake with fault injection |
| `sdm/testing/hil_suite.hpp` | `runAssertions()` + `characterise()`, templated so the same code runs on the fake in CI and on hardware |
| `examples/sdm_flash/main.cpp` | CLI. The hardware backend plugs in at one marked line |
| `tests/` | doctest suites (26 cases), `cmake -B build && cmake --build build && ctest --test-dir build` |

To run the HIL suite on hardware: write a small main that constructs the real `SdmService`,
calls `hil::runAssertions(sdm, cfg)` and prints the results, then calls
`hil::characterise(sdm, cfg, jsonl_file)`. Set `cfg.scratchBase` to a region that is safe to
clobber.
