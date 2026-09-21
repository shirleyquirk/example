# SPEC — uio-memcpy-bench

## 1. Purpose

Find the fastest correct way to copy between a **Device-nGnRnE userspace mapping** (UIO, backed by a `no-map` reserved DRAM region) and **normal cacheable RAM** on a Cortex-A53, in both directions, from userspace only.

The deliverable is data plus a recommendation: which instruction pattern wins per direction and size range, and why. This is a measurement tool, not a library.

**Correctness and speed are separate activities.** Correctness is established by the generator's model checker, the host tests, and the `verify` mode — none of which need the board. Speed is measured by the `bench` mode, which does need the board. Everything up to first board contact is developed and tested on an ordinary x86-64 host.

## 2. Platform facts (confirmed)

| Item | Value |
|---|---|
| SoC / core | Intel Agilex 7 HPS, Cortex-A53, AArch64 Linux |
| Device mapping | UIO `UIO_MEM_PHYS` → `pgprot_noncached` → **Device-nGnRnE** (confirmed on hardware) |
| Backing | `no-map` reserved DRAM region, **not** MMIO registers |
| Scope | Userspace only. No kernel changes, no mapping-attribute changes |

Implications of Device-nGnRnE:
- Unaligned accesses fault (SIGBUS) regardless of `SCTLR_EL1.A`.
- No gathering (nG): the core may not merge accesses. No reordering (nR). No early write ack (nE): a store is not complete until the endpoint responds.
- `PRFM` has no effect. Cache maintenance and `DC ZVA` are meaningless or faulting. glibc `memcpy`/`memset` must never be pointed at this mapping.

### 2.1 Board parameters

There is no table of values here. Every board-specific value lives as an empty variable define in `scripts/board_env.sh`, which also documents the kernel/boot setup the measurements depend on (CPU isolation, `nohz_full`, region idleness). Nothing in phases A–D reads that file; the first thing that does is the first board phase.

## 3. Device-side access rules (safety-critical)

These apply to every access the harness or any variant makes to the UIO mapping.

- **D1: Naturally aligned.** Every device access of size S bytes is at an address that is a multiple of S. For multi-register instructions (`LDP`, `LD1 {…}`), the address must be a multiple of the **total** bytes transferred by the instruction. This is stricter than the architecture requires, chosen deliberately.
- **D2: In range.** No device byte outside `[dev_ptr, dev_ptr + n)` is ever read or written by a copy function. This includes no over-reads and no "overlapping tail" tricks.
- **D3: Exactly once.** Each device byte in range is accessed exactly once per copy.
- **D4: No forbidden instructions on the device side.** No `PRFM`, `DC *`, `LDNP`/`STNP`, exclusives (`LDXR`/`STXR`/…), atomics, `LDAR`/`STLR`, or any barrier inside a copy function. The RAM side of a copy has no such restriction; the instruction tables (§5.1) are separate for this reason.
- **D5: Window only.** The harness only ever touches the device window defined in §7.2, including margins and guards.
- **D6: Accessor discipline.** C code touching the device side does so only through `volatile` fixed-width accessors (`dev_ld8/16/32/64`, `dev_st8/16/32/64`) defined in one header. No `memcpy`, `memset`, or struct copies on device pointers.

**D3 is not observable at runtime.** A byte written twice looks identical to a byte written once. D3 is enforced by the op-list simulator (§6.4), not by the pattern check (§7.4). This is why the generator's model checker is the primary correctness gate and the board run is a confirmation.

### 3.1 No library copies, anywhere in a copy path

Neither `memcpy`, `memmove`, `memset`, `__builtin_memcpy` nor any other library or builtin block-copy appears in a copy function, in the head/tail, or in a baseline. The RAM side of an unaligned access uses a packed-struct typed load/store, which compiles to a single unaligned `LDR`/`STR` on AArch64:

```c
/* One unaligned load/store; AArch64 permits these on Normal memory. */
struct u64_un { uint64_t v; } __attribute__((packed, may_alias));
```

Harness setup code (buffer allocation, prefaulting the RAM side) may use `memset` on the RAM side only. The pattern fill and check (§7.4) are byte loops by construction.

## 4. Copy function contract

```c
typedef void (*copy_fn)(void *dst, const void *src, size_t n);
```

- read direction: `src` is device, `dst` is RAM. write direction: the reverse.
- Any `n` ≥ 0 and any alignment of either pointer.
- Each variant is specialised to one direction.
- A copy function = **shared head** (C) + **generated body** (asm) + **shared tail** (C). Head/tail strategy is not a sweep axis before phase G.

### 4.1 Shared head/tail (`src/headtail.c`)

- **Head:** while the device pointer is not aligned to `Wdev` (the variant's device instruction width) and bytes remain, do the largest power-of-two access (1/2/4/8) that is aligned at the current device address and fits in the remaining bytes. Device side uses D6 accessors. RAM side uses a packed-struct access of the same size (§3.1); the RAM side may be unaligned.
- **Tail:** the remaining bytes (< `Wdev`) are copied with descending aligned power-of-two accesses (max 8), same rules.
- If `n` is too small to reach alignment, the head/tail logic alone completes the copy and the body is not called.

### 4.2 Generated body

```c
void body_<id>(void *dst, const void *src, size_t nbytes);
```

- On entry the device pointer is `Wdev`-aligned and `nbytes` is a multiple of `Wdev`. `nbytes` may be 0.
- On return, exactly `nbytes` bytes have been copied. Bytes are counted, not chunks, so batch sizes need not be powers of two and the device and RAM sides need not use the same instruction width.
- Leaf function.
- **AAPCS64 register budget.** Two tiers, selected per generator run:
  - **`caller`** (default): clobbers only `x0–x17`, `v0–v7`, `v16–v31`, no stack frame. With `x0–x2` holding the arguments, that is **15 X** (`x3–x17`) and **24 V** available for data.
  - **`saved`**: additionally uses `x19–x28` and `v8–v15`, saving and restoring them in a prologue/epilogue with `STP`/`LDP` to the stack (for `v8–v15` the architecture only requires the low 64 bits be preserved, but we save the full `Q` registers since we use the full width). That is **25 X** and **32 V**. Never `x18` (platform register), never `sp`.
  The save/restore costs ~10 cached stores and loads per call, which is noise for large `n` and is not noise for small `n`. The generator records the tier in the variant name and the CSV so the two are never compared blind.

## 5. Variant space

### 5.1 Instruction tables (`gen/isa.py`) — extensible by design

Two independent tables, one for the device side and one for the RAM side. Adding an instruction is a one-row edit to a table; no other file changes. Each row declares:

| Field | Meaning |
|---|---|
| `id` | short name used in variant names, e.g. `x8`, `qp32`, `l4d64` |
| `mnemonic` | load/store templates, e.g. `("ldp {r0}, {r1}, [{base}, #{off}]", "stp …")` |
| `width` | bytes moved per instruction |
| `regclass` | `"x"` or `"v"` |
| `nregs` | registers consumed per instruction |
| `dev_ok` | may appear on the device side (false for `LDNP`/`STNP`, `PRFM`, …) |
| `min_offset` / `max_offset` / `offset_step` | addressing-mode limits for the immediate-offset form |
| `notes` | free text, rendered as a comment in the `.S` |

The device table starts as:

| id | Device instruction | W (bytes) | regs/instr |
|---|---|---|---|
| `x8` | `LDR`/`STR Xn` | 8 | 1 X |
| `xp16` | `LDP`/`STP Xn, Xm` | 16 | 2 X |
| `q16` | `LDR`/`STR Qn` | 16 | 1 V |
| `qp32` | `LDP`/`STP Qn, Qm` | 32 | 2 V |
| `l4b64` | `LD1`/`ST1 {4 regs}.16b` | 64 | 4 V |
| `l4d64` | `LD1`/`ST1 {4 regs}.2d` | 64 | 4 V |

`l4b64` vs `l4d64` is deliberate. On non-Gathering memory, element size may determine how the access is split on the bus: `.16b` could become up to 64 byte-sized transactions, while `.2d` becomes 8-byte ones. **This is speculation. How the A53 actually behaves is what we're measuring.** The same uncertainty applies to whether `LDR Q` / `LDP` issue as one transaction or several.

The RAM table starts as the same rows with `dev_ok` irrelevant, plus `w4`/`x8`-class narrow forms for tiling remainders.

### 5.2 Batch shape

A batch moves **T bytes**. It is described by:

- `dev_instr` and `dev_count`: the device side issues `dev_count` instructions of width `Wdev`, so `T = dev_count × Wdev`.
- `ram_instr`: the RAM side tiles the same `T` bytes greedily with `ram_instr`, falling back to narrower rows of the RAM table for any remainder. The RAM side has no alignment constraint, so its instruction choice is independent of the device side's.

`dev_count` ∈ any positive integer from a configurable list; the default list is `{1, 2, 3, 4, 6, 8, 12, 16}` — **not** restricted to powers of two. A combination is skipped if `T` is not a multiple of `Wram`, or if register allocation exceeds the budget; every skip is printed with its reason.

### 5.3 Schedule

- **`batch`:** issue the whole batch's device accesses, then the whole batch's RAM accesses. Register need = one batch's worth.
- **`pipe`:** software-pipelined, unrolled ×2 with two alternating register sets, so the device accesses for batch *i+1* are issued before batch *i*'s RAM side completes. Register need = two batches' worth.

  The premise is that a device load's latency can be overlapped with the previous batch's RAM stores. Whether the A53 permits more than one outstanding Device-nGnRnE transaction is exactly the open question; nR forbids *reordering* of device accesses relative to each other, which is not the same as forbidding overlap, but the core may serialise them anyway. **Speculation.** If phase-D/E data shows `pipe` never beating `batch`, it is dropped rather than debugged. `pipe` carries all the interesting failure modes (unguarded prologue, register-set aliasing, epilogue drain), so §6.4 tests for those specifically.

### 5.4 Feasibility

Register need is **computed from the op list by liveness analysis**, not from a closed-form formula, so a newly added instruction gets a correct feasibility answer for free. A combination whose need exceeds the tier's budget (§4.2) is not generated; the generator prints each skipped combination and why. The total variant count is whatever the tables produce and is not a target.

### 5.5 Baselines (hand-written C, `src/baselines.c`)

- `base_u8`: volatile byte loop on the device side.
- `base_u64`: shared head/tail + volatile aligned 8-byte loop.
- `control_glibc`: glibc `memcpy` **RAM→RAM only**, to sanity-check the timing harness. Never pointed at the device, never at the fake device.

## 6. Generator (`gen/`)

### 6.1 Pipeline

`isa.py` (instruction tables) → `variants.py` (parameter space, feasibility) → `emit.py` (builds an **op-list model** per variant, then renders `.S` from it) → `validate.py` (checks the model, lints the rendered `.S`, and re-parses the assembled object) → outputs `build/gen/variants.S` and `build/gen/variants_table.c`.

The op list is the single source of truth. The `.S` file is rendered from it, never hand-edited.

### 6.2 Body structure

The body is a sequence of segments. Each segment declares an explicit **precondition on `nbytes`**, and the renderer emits the guard that enforces it. No segment may be entered speculatively — in particular a `pipe` prologue must not issue a batch's device accesses before it is known that a batch's worth of bytes remains, since that would break D2 and D3.

```
  (pipe only)  if nbytes < 2*T: skip to the single-instruction loop
  (pipe only)  prologue: issue batch 0's device-side accesses
  batched loop: while nbytes >= T    (pipe: unrolled x2, alternating register sets)
  (pipe only)  epilogue: drain the last in-flight batch
  single loop:  while nbytes >= Wdev
  return                              (remaining bytes < Wdev are the C tail's job)
```

`T`, `Wdev` and `Wram` differ per variant and the loops above are expressed in bytes, so the structure imposes no relationship between the device and RAM instruction widths, between `T` and any power of two, or between the strides of the two sides. Pointer advance per segment is per-side and taken from the op list.

Each segment is a straight-line op list with symbolic offsets relative to the current device/RAM pointers. Each op records: side (dev/ram), load/store, byte offset, size, registers, and mnemonic.

### 6.3 Variant table

`variants_table.c` exports:

```c
struct variant {
  const char *name; int dir; int wdev; const char *dev_kind;
  int dev_count; int t; const char *ram_kind; const char *sched;
  const char *regtier; copy_fn fn;
};
extern const struct variant variants[]; extern const size_t n_variants;
```

`fn` is a C wrapper: head → `body_<id>` → tail. Names follow `<dir>_<devkind>_n<count>_<ramkind>_<sched>[_saved]`, for example `rd_qp32_n4_q16_pipe`.

### 6.4 Validator (`gen/validate.py`) must check, for every variant

1. **Simulation.** Interpret the op list over a model memory for `nbytes` = 0 … 4·T + Wdev + 3 (and every multiple of `Wdev` in that range), asserting: device accesses satisfy D1–D3 relative to a `Wdev`-aligned base; the RAM side covers the same byte range exactly once; and the resulting model memory equals a reference copy byte for byte.
2. **Registers.** Only registers permitted by the tier (§4.2) are used, and no register is written before its previous value has been consumed. `pipe` variants are additionally checked for register-set aliasing between the two unrolled halves.
3. **Guards.** Every segment's precondition is enforced by an emitted branch. A `pipe` prologue reachable with `nbytes < 2·T` is a hard failure.
4. **Lint of the rendered `.S`.** No mnemonic with `dev_ok = false` on the device side (D4), no forbidden registers, exactly one global symbol per variant, every immediate offset within its addressing-mode limits.
5. **Assemble and re-parse.** Assemble `variants.S` with `aarch64-linux-gnu-as`, disassemble with `aarch64-linux-gnu-objdump -d`, parse the disassembly back into an op list, and assert it matches the model. This catches renderer bugs, malformed operands and out-of-range immediates that a text lint cannot, and needs no emulator and no target hardware. If the cross-binutils are absent, this check fails the build with a message naming the package; it is never silently skipped.
6. **Build gate.** Any failure exits non-zero and `make` fails. A variant that fails is never dropped silently.

### 6.5 Host tests

- `tests/test_headtail.c` is built natively (x86-64 is fine) with the D6 accessors redefined to log `(addr, size, op)`. For device offsets 0–127 × `n` 0–600 × every `Wdev` in the table, it asserts D1–D3 and a correct copy. Built with `-fsanitize=address,undefined -fno-sanitize-recover=all`.
- `tests/test_validate.py` feeds the validator deliberately broken op lists — misaligned, overlapping, out-of-range, forbidden register, forbidden mnemonic, unguarded `pipe` prologue, aliased `pipe` register sets, off-by-one range — and asserts each is rejected.
- `tests/test_harness.c` runs the whole harness against the fake device (§7.2) and asserts the pattern checker catches injected faults: a copy short by one byte, long by one byte, displaced by 64 bytes, and one that writes its source.

No emulator is used. Correctness of the generated code rests on (a) the model simulation, (b) the disassembly re-parse proving the emitted instructions are the model's, and (c) the head/tail and harness tests, which execute natively.

## 7. Harness (`mcbench`, `src/`)

### 7.1 CLI

```
mcbench info                        map size, CNTFRQ_EL0, cpu, kernel, variant count
mcbench list                        list variant names
mcbench verify  --uio /dev/uioN --map M | --fake-dev BYTES
        [--dir read|write|both] [--variants SUBSTR|all]
        [--sizes LIST|default] [--dev-offsets LIST] [--ram-offsets LIST]
        [--seed S] [--out results.csv]
mcbench bench   --uio /dev/uioN --map M --cpu C | --fake-dev BYTES
        [--dir …] [--variants …] [--sizes …] [--dev-offsets …] [--ram-offsets …]
        [--samples N=31] [--seed S] [--max-size BYTES] [--control] --out results.csv
```

Correctness and timing are separate subcommands. `bench` runs one verification pass per combination before timing it; `verify` never times anything and sweeps far more combinations.

`--fake-dev BYTES` replaces the UIO mapping with an anonymous `mmap` of that size, so the entire harness — layout, margins, patterns, verification, timing machinery, CSV — runs on any machine, including a non-AArch64 host. Every run prints a one-line banner naming the device source; `bench --fake-dev` additionally prints `TIMING A FAKE DEVICE — THESE NUMBERS SAY NOTHING ABOUT THE REAL MAPPING` to stderr. The CSV carries a `devsrc` column (`uio` or `fake`), and `analyze.py` refuses to mix the two in one report.

### 7.2 Memory layout

- The device window is the UIO map, mmapped at offset `M * pagesize`; its size comes from `/sys/class/uio/uioN/maps/mapM/size`. Under `--fake-dev` it is an anonymous mapping of the given size.
- Guards of G = 256 bytes sit at each end of the window. The working area is `[G, size − G)`. The device base for a test is `working_start + dev_offset`, where `working_start` is 4096-aligned.
- **Per-test margins.** Immediately before and after each test's byte range, on *both* sides, sits a margin of M = 256 bytes carrying the margin pattern (§7.4). Margins are checked after every copy. Window guards catch gross runaways; margins catch the off-by-one, which is the failure mode generated assembly actually has.
- The device-side fill and check use aligned 8-byte D6 accessors, so they operate on the 8-byte-aligned envelope of `[base, base+n)`. The margins are sized and positioned so this envelope always lies inside them; the envelope bytes outside the copy range carry the margin pattern and are checked like any other margin byte.
- The RAM buffer comes from `posix_memalign(4096)` with the same margin/guard layout, and is prefaulted.
- Refuse to run (exit non-zero with a message) if `max_size + max_offset + 2M + 2G` exceeds the window.

### 7.3 Process setup

`sched_setaffinity` to `--cpu`, then `mlockall(MCL_CURRENT | MCL_FUTURE)`. Fail loudly if either fails. `bench` requires `--cpu`; `verify` does not.

A `SIGBUS` and `SIGSEGV` handler is installed for the duration of every copy. On fault it prints the current variant, direction, size, `dev_off`, `ram_off`, the faulting address and its offset within the window, flushes the CSV, and exits non-zero. Without this a single D1 violation kills the process and takes the run's diagnosis with it.

### 7.4 Pattern verification

Modelled on the kernel's `dmatest`. Every byte of every buffer carries a tagged pattern:

```
bit 7      side:   1 = source buffer, 0 = destination buffer
bit 6      region: 1 = inside the copy range, 0 = margin/guard
bits 5..0  mix(global_byte_offset, seed, buffer_id) & 0x3f
```

`mix` is a cheap integer hash, not `offset & 0x3f`. A plain masked counter has period 64, so a copy displaced by a multiple of 64 bytes — exactly the displacement a batch-stride bug produces — reproduces the expected pattern and passes. A hash makes any displacement fail with probability 63/64 per byte, so multi-byte displacements are caught with certainty. The seed is per run and appears in the CSV.

For each (variant, size, dev_off, ram_off):
1. Fill the source range with `side=1, region=1`, the source margins with `side=1, region=0`, the destination range and margins with `side=0` and the matching region bit.
2. Run the copy once.
3. Check the destination range byte for byte against the *source* pattern, the destination margins against their poison, the whole source buffer and its margins unmodified, and both window guards untouched.

The tag bits make a failure self-describing, which is the point:

| Symptom | Diagnosis |
|---|---|
| destination margin byte has `side=1` | copy wrote past its range — off-by-one or bad stride |
| destination range byte still has `side=0` | copy fell short, or never ran |
| destination range byte has `side=1` but the wrong mix | copied from the wrong offset — stride or index bug |
| any source byte changed | copy wrote its source — pointer or direction bug |

`verify` runs each combination twice, with `seed` and `~seed`, so a byte that accidentally matches under one pattern fails under the other.

Any failure aborts the run, printing the variant, size, offsets, the first bad offset, and both bytes decoded into (side, region, expected-offset).

**D3 is not checked here** — see §3. The op-list simulation is what enforces it.

### 7.5 Timing

- Timer: `CNTVCT_EL0`, read as `isb; mrs`, behind a two-line `now_ticks()`/`ticks_per_sec()` pair whose only other implementation is `clock_gettime(CLOCK_MONOTONIC)` for non-AArch64 host builds, so the timing path is testable off-board. Convert with `CNTFRQ_EL0`, cross-checked once at startup against `CLOCK_MONOTONIC` and refused if they disagree by more than 1%; firmware does sometimes program `CNTFRQ_EL0` wrongly and every number in the report scales with it.
- Each sample: `isb; t0 = cntvct; for (r = 0; r < R; r++) fn(dst, src, n); dsb sy; isb; t1 = cntvct`.
- **The `dsb sy` is once per sample, never inside the rep loop.** A sample is ≥ 100 µs, so one barrier costs well under 0.1% and a per-call barrier would cost far more than the copy it followed. It is there because nGnRnE's no-early-ack guarantees the *endpoint* has the data before the write is complete, but does not stop the core retiring the store before then; without the barrier, `t1` could be read with the last stores still in flight. The error it removes is bounded by the store buffer depth and is therefore a constant, which matters most at the small sizes where the constant is the measurement.
- Calibrate R per combination so each sample lasts ≥ 100 µs.
- Take `--samples` samples. Record min, median and p90 of ticks per call.
- Combination order is randomised with `--seed`, which is written to the CSV.
- Rows are written and flushed as they are produced, not at the end.
- Print progress and an ETA to stderr.

Because R repeats the same copy back to back, the RAM side is warm in L1/L2 for any size that fits. This is a stated measurement condition, not an accident; the report says so, and it is the effect the phase-G non-temporal axis exists to probe.

### 7.6 Default sweeps

- **`verify`:** sizes 0–600 (every value) plus 1K, 4K, 64K; `dev_off` 0–127; `ram_off` ∈ {0, 1, 5, 63}. This is the correctness sweep and does not need to be fast.
- **`bench` size sweep:** sizes 1–64 (every value), 96, 128, 192, 256, 384, 512, 768, 1K, 1.5K, 2K, 4K, 8K, 16K, 64K, 256K, 1M (clamped to the window). `dev_off = 0`, `ram_off = 0`.
- **`bench` offset sweep:** `dev_off` ∈ {0, 1, 2, 3, 4, 7, 8, 12, 15, 16, 24, 31, 32, 48, 63}, `ram_off` ∈ {0, 5}, sizes {1–64, 4K}, for the baselines and the top 10 variants per direction from the size sweep.

## 8. Output (`results.csv`)

Columns: `variant, dir, devsrc, dev_kind, wdev, dev_count, t, ram_kind, sched, regtier, size, dev_off, ram_off, samples, reps_per_sample, min_ticks, med_ticks, p90_ticks, cntfrq, med_ns, med_MBps, seed, git_sha, kernel, hostname, cpu, timestamp`.

One row per combination, flushed as produced. Baseline rows leave the generated-variant columns empty rather than inventing values. `git_sha` is embedded at build time.

## 9. Analysis (`scripts/analyze.py`)

Input: one or more CSVs. Output: `report.md` containing:

1. Per direction, the top 5 variants by median throughput in each size bucket: ≤64 B, 65–512 B, 513 B–4 KiB, >4 KiB.
2. The effect of `Wdev` at fixed batch/schedule, and of `dev_count` at fixed kind/schedule, as small tables.
3. `l4b64` vs `l4d64` head-to-head.
4. Small-size (1–64 B) cost versus `base_u64`.
5. A noise check: flag rows where p90/median > 1.2.
6. A recommendation: best variant per direction per bucket, and whether one variant is within 5% of the best everywhere.

**Distinct-code-path collapsing.** For `n < Wdev` the body never runs and every variant with that `Wdev` executes identical head/tail code; for `n < T` the batched loop never runs and every variant sharing `(Wdev, ram_kind)` is identical. Ranking such rows against each other ranks noise. `analyze.py` groups rows by the code path actually executed, reports one number per group, and states the size above which each axis begins to mean anything (roughly `n ≥ 2·T`).

Optional PNG plots if matplotlib is available.

## 10. Non-goals

Kernel code; changing mapping attributes; UIO→UIO or RAM→RAM optimisation; prefetch and non-temporal variants (phase G only, gated); head/tail strategy variants (phase G only, gated); auto-tuning or search algorithms; multi-threaded copies; emulators; any other CPU or SoC.

## 11. Repo layout

```
CLAUDE.md SPEC.md ROADMAP.md NOTES.md Makefile
gen/      isa.py variants.py emit.py validate.py gen_variants.py
src/      main.c uio.c uio.h timing.h devio.h headtail.c headtail.h
          pattern.c pattern.h baselines.c
tests/    test_headtail.c test_harness.c test_validate.py
scripts/  board_env.sh run_on_device.sh analyze.py
build/    (generated; not committed)
```

Makefile targets:

| target | needs | does |
|---|---|---|
| `gen` | python3 | run the generator and validator; any failure fails the build |
| `check` | python3, `aarch64-linux-gnu-as`/`objdump` | `gen` plus the assemble-and-re-parse gate and `tests/test_validate.py` |
| `host-test` | host cc | build and run the native tests with ASan+UBSan |
| `all` | cross `$(CC)` from the Yocto SDK | `gen` plus cross-compile `mcbench` |
| `clean` | | |

`all` assumes the SDK environment is sourced. Build target code with `-O2 -Wall -Wextra -Werror`. Host tests additionally with `-fsanitize=address,undefined -fno-sanitize-recover=all`.

`scripts/board_env.sh` holds the board parameters as empty variable defines and documents the required kernel/boot setup. `scripts/run_on_device.sh` sources it, copies `build/mcbench` to `$BOARD:/tmp/`, runs it with the given arguments, and copies any `--out` file back. It does nothing else.
