# SPEC — uio-memcpy-bench

## 1. Purpose

Find the fastest correct way to copy between a **Device-nGnRnE userspace mapping** (UIO, backed by a `no-map` reserved DRAM region) and **normal cacheable RAM** on a Cortex-A53, in both directions, from userspace only.

The deliverable is data plus a recommendation: which instruction pattern wins per direction and size range, and why. This is a measurement tool, not a library.

**Correctness and speed are separate activities.** Correctness is established by the generator's model checker, static checks on the rendered code, and execution of every variant under an emulator — none of which need the board. Speed is measured by the `bench` mode, which does need the board and is never run under emulation. Everything up to first board contact is developed and tested on an ordinary x86-64 host.

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

### 5.2 Block and lookahead

A variant is five things: direction, device instruction, RAM instruction, **block bytes T**, and **lookahead bytes**.

A block moves T bytes. The load side issues `T/Wl` instructions, the store side `T/Ws`. A **schedule** is any interleaving of those two sequences in which a store issues only after every load covering its bytes has issued. There is exactly one knob:

> **lookahead** — the number of bytes that may be loaded but not yet stored.

- `lookahead = max(Wl, Ws)` → lockstep: load, store, load, store.
- `lookahead = T` → every load, then every store.
- in between → everything else.

Register need is the peak of that same quantity, so the knob that buys overlap is the knob that spends registers. There is no separate batch-size axis and no separate schedule enum: T sets how much is unrolled, lookahead sets how much of it overlaps.

Both sides must share a register class, because data flows load → store through registers and crossing classes would need an `FMOV` per chunk — which would be what we were measuring. The **group** size `G = lcm(Wl, Ws)` is the unit both sides tile evenly; T is a multiple of G, and lookahead is a multiple of G. The default T list is `{1, 2, 3, 4, 6, 8, 12, 16} × G` — **not** restricted to powers of two, since the loop guard is a byte comparison and non-powers cost nothing.

### 5.3 What happened to `batch` and `pipe`

They are the two extreme lookahead values, so they no longer need naming. More importantly, the **prologue and epilogue are gone**.

Classic software pipelining overlaps across the loop back-edge, which is what requires a prologue to prime and an epilogue to drain — and the prologue is exactly where an unguarded batch of device loads reads past the end of the buffer. The same overlap is available from a larger block: a block of 2T with lookahead T keeps one batch in flight throughout. The only thing lost is overlap across the back-edge itself, one bubble per block.

In exchange, every segment is a straight-line run guarded by a single comparison, with nothing live across an iteration and nothing live between segments. Reviewability decided this, not elegance: the failure mode being designed out is the one a human reviewer is least likely to spot.

Whether overlap helps at all is the open question. `nR` forbids device accesses being *reordered* relative to each other, which is not the same as forbidding overlap, but the A53 may serialise them anyway. **Speculation.** If the data shows lookahead above one group never wins, that half of the space is dropped rather than debugged.

### 5.4 Feasibility

Register need is **computed by building the variant and allocating its registers**, not from a closed-form formula, so a newly added instruction gets a correct answer without anyone deriving one. Allocation hands out one group of `G` bytes at a time as a run of consecutive registers, which satisfies `LD1`/`ST1` contiguity on both sides without a special case and needs no interference graph — groups are born and die in order. It is slightly conservative, deliberately: a register allocator that cannot be checked by reading it is not worth the variants it buys.

A combination whose allocation fails is not generated, and every skip is printed with its reason. Variants that render identical instruction sequences are deduplicated. The total count is whatever the tables produce and is not a target.

### 5.5 Baselines (hand-written C, `src/baselines.c`)

- `base_u8`: volatile byte loop on the device side.
- `base_u64`: shared head/tail + volatile aligned 8-byte loop.
- `control_glibc`: glibc `memcpy` **RAM→RAM only**, to sanity-check the timing harness. Never pointed at the device, never at the fake device.

## 6. Generator (`gen/`)

### 6.1 Pipeline

`isa.py` (instruction tables) → `variants.py` (parameter space, feasibility) → `emit.py` (builds an **op-list model** per variant, then renders `.S` from it) → `validate.py` (checks the model, lints the rendered `.S`, and re-parses the assembled object) → outputs `build/gen/variants.S` and `build/gen/variants_table.c`.

The op list is the single source of truth. The `.S` file is rendered from it, never hand-edited.

### 6.2 Body structure

The entire control flow of every generated body:

```
  while (nbytes >= T) { block_T }     the overlap happens here
  while (nbytes >= G) { block_G }     remainder, lockstep
  return                              nbytes < G is the C tail's problem
```

Two loops, each guarded by its own comparison against a literal, each a straight-line run of accesses, nothing live across an iteration, nothing live between the loops, no prologue, no epilogue. When `T == G` the first loop is omitted rather than emitted twice. This is the whole structure, for every variant, at every width. It is stated this plainly because a human has to be able to prove it correct by reading it.

The loops count **bytes**, not chunks, so nothing relates `Wdev` to `Wram`, `T` to any power of two, or either side's stride to the other's.

**Addressing is post-index throughout** (`ldr x3, [x1], #8`). `LD1`/`ST1` have no immediate-offset form, so post-index is the only rule that covers every instruction; the pointer bump is free; there are no immediate ranges to check because there are no immediates; and each side's k'th access is at `base + k·W` **by construction**, which is what makes D1 provable by reading the code rather than by trusting a simulation.

Each op records: side (dev/ram), load/store, byte offset, size, registers, and instruction.

The generator can print a human-readable trace of any variant (`make explain NAME=…`) showing each access with its registers and the in-flight byte count beside it — the quantity that both creates the overlap and consumes the registers.

### 6.3 Variant table

`variants_table.c` exports:

```c
struct variant {
  const char *name; int dir; const char *dev_kind; int wdev;
  const char *ram_kind; int wram; int block; int lookahead; int group;
  const char *regtier; int need; copy_fn fn;
};
extern const struct variant variants[]; extern const size_t n_variants;
```

`fn` is a wrapper calling the shared `ht_copy` (head → `body_<id>` → tail), so the head/tail logic exists once rather than per variant. Names follow `<dir>_<devkind>_<ramkind>_t<T>_la<lookahead>`, for example `rd_qp32_q16_t128_la64`.

### 6.4 Validator (`gen/validate.py`) must check, for every variant

1. **Simulation.** Interpret the op list over a model memory for every `nbytes` the wrapper can pass — multiples of `G` from 0 to 4·T + 4·G — asserting: device accesses satisfy D1–D3 relative to a `Wdev`-aligned base; the destination is covered exactly once; and every destination byte carries the source byte that should have reached it, traced through the registers, so a wrong register and a wrong offset fail as loudly as a missing store.
2. **Registers.** Only registers permitted by the tier (§4.2); `LD1`/`ST1` operands consecutive; no register overwritten while it still holds bytes nobody has stored; no block ending with data still in registers.
3. **Guards.** Each loop's byte comparison is emitted and matches its block size. Since there is no prologue, there is no segment that can be entered speculatively.
4. **Lint of the rendered `.S`.** D4 in two parts: barriers, cache maintenance, exclusives and atomics are forbidden *anywhere* in a body whichever side they name; `PRFM`/`LDNP`/`STNP` are forbidden on the device side only, since they are phase-G candidates for the RAM side. Plus no `x18` or `sp`, no callee-saved registers in the `caller` tier, exactly one global symbol per body.
5. **Assemble and re-parse.** Assemble `variants.S` with `aarch64-linux-gnu-as`, disassemble with `aarch64-linux-gnu-objdump -d`, parse the disassembly back into an op list, and assert it matches the model. This catches renderer bugs, malformed operands and out-of-range immediates that neither a text lint nor execution reliably catches. If the cross-binutils are absent, this check fails the build with a message naming the package; it is never silently skipped.
6. **Build gate.** Any failure exits non-zero and `make` fails. A variant that fails is never dropped silently.

### 6.5 Tests

**Native (x86-64) tests.**

- `tests/test_headtail.c` is built natively with the D6 accessors redefined to log `(addr, size, op)`. For device offsets 0–127 × `n` 0–600 × every `Wdev` in the table, it asserts D1–D3 and a correct copy. Built with `-fsanitize=address,undefined -fno-sanitize-recover=all`.
- `tests/test_validate.py` mutates a known-good variant into each defect the generator could plausibly have — misaligned access, a device byte touched twice, a read past the block, a dropped store, a store reading the wrong register, a callee-saved register, non-consecutive `LD1` operands, a store before its load, `PRFM` on the device side, a barrier anywhere, `x18`, two globals in one body, and rendered code that disagrees with its model — and asserts each is caught by the gate that should catch it. It runs *before* generation in `make check`: a validator nobody has watched fail proves nothing about the variants it passes.
- `tests/test_harness.c` runs the whole harness against the fake device (§7.2) and asserts the pattern checker catches injected faults: a copy short by one byte, long by one byte, displaced by 64 bytes, and one that writes its source.

**Emulated (`qemu-aarch64-static`) tests.** `mcbench` is cross-built with `aarch64-linux-gnu-gcc -static` and `mcbench verify --fake-dev` is run under qemu for every variant over the full correctness sweep. This executes the real binary — generated bodies, C wrappers, head/tail, pattern checker — on real AArch64 semantics, and catches what no static check can:

- **AAPCS64 violations.** Under `verify`, every copy is called through `poison_call` (`tests/poison.S`): an assembly wrapper that loads `x18`–`x28` and `d8`–`d15` with known values, calls the copy, and reports the first register destroyed. Relying on a clobber to happen to break the caller is luck; this makes it deterministic.
- **Escapes from the window.** The guard pages of §7.2 are `PROT_NONE`, so any access outside the mapping faults under qemu exactly as it would on the board. An unguarded `pipe` prologue reading one batch past the end is caught as a `SIGSEGV`, not as a silent pass.

**What emulation does not give us.** qemu does not model Device-memory alignment faults — a misaligned `LD1` that would `SIGBUS` on the board succeeds under qemu. The op-list simulator is the alignment gate (§6.4.1) and always will be. qemu also says nothing about timing; `bench` is never run under it, and the fake-device banner covers the case where someone tries.

The cross compiler here is *not* the Yocto SDK — different libc, different tuning. It is a correctness tool only; `make all` still builds the shipped binary with the SDK.

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
- **The mapping sits inside a `PROT_NONE` reservation.** The harness first reserves `window + 2 pages` of address space with `PROT_NONE`, then maps the UIO window (or the fake device) `MAP_FIXED` one page in. Any access outside the window then faults immediately instead of landing on whatever the allocator put next door. On the board this turns a window escape into an instant, located `SIGBUS`/`SIGSEGV` report (§7.3) rather than silent corruption of another mapping; under qemu it is what catches an over-reading prologue.
- Guards of G = 256 bytes sit at each end of the window, inside it. The working area is `[G, size − G)`. The device base for a test is `working_start + dev_offset`, where `working_start` is 4096-aligned.
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

On AArch64 builds, `verify` makes every call through `poison_call` so an AAPCS64 clobber is caught here too, not only under emulation. `bench` calls directly — the wrapper is cheap but it is not free, and it has no business inside a timed loop.

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

Columns: `variant, dir, devsrc, dev_kind, wdev, ram_kind, wram, block, lookahead, group, regtier, need, size, dev_off, ram_off, samples, reps_per_sample, min_ticks, med_ticks, p90_ticks, cntfrq, med_ns, med_MBps, seed, git_sha, kernel, hostname, cpu, timestamp`.

One row per combination, flushed as produced. Baseline rows leave the generated-variant columns empty rather than inventing values. `git_sha` is embedded at build time.

## 9. Analysis (`scripts/analyze.py`)

Input: one or more CSVs. Output: `report.md` containing:

1. Per direction, the top 5 variants by median throughput in each size bucket: ≤64 B, 65–512 B, 513 B–4 KiB, >4 KiB.
2. The effect of `Wdev` at fixed block/lookahead, of block at fixed widths, and of **lookahead at fixed everything else** — the last is the one that answers whether the A53 overlaps Device-nGnRnE transactions at all.
3. `l4b64` vs `l4d64` head-to-head.
4. Small-size (1–64 B) cost versus `base_u64`.
5. A noise check: flag rows where p90/median > 1.2.
6. A recommendation: best variant per direction per bucket, and whether one variant is within 5% of the best everywhere.

**Distinct-code-path collapsing.** For `n < Wdev` the body never runs and every variant with that `Wdev` executes identical head/tail code; for `n < T` the batched loop never runs and every variant sharing `(Wdev, ram_kind)` is identical. Ranking such rows against each other ranks noise. `analyze.py` groups rows by the code path actually executed, reports one number per group, and states the size above which each axis begins to mean anything (roughly `n ≥ 2·T`).

Optional PNG plots if matplotlib is available.

## 10. Non-goals

Kernel code; changing mapping attributes; UIO→UIO or RAM→RAM optimisation; prefetch and non-temporal variants (phase G only, gated); head/tail strategy variants (phase G only, gated); auto-tuning or search algorithms; multi-threaded copies; timing under emulation; any other CPU or SoC.

## 11. Repo layout

```
CLAUDE.md SPEC.md ROADMAP.md NOTES.md SETUP.md Makefile
gen/      isa.py model.py variants.py emit.py validate.py gen_variants.py
src/      main.c uio.c uio.h timing.h devio.h headtail.c headtail.h
          pattern.c pattern.h baselines.c
tests/    test_headtail.c test_harness.c test_bodies.c test_validate.py poison.S
scripts/  board_env.sh run_on_device.sh analyze.py
build/    (generated; not committed)
```

Makefile targets:

| target | needs | does |
|---|---|---|
| `deps` | root | install the whole off-board toolchain (see SETUP.md) |
| `gen` | python3 | run the generator and validator; any failure fails the build |
| `explain NAME=…` | python3 | print a human-readable trace of matching variants |
| `check` | python3, `aarch64-linux-gnu-as`/`objdump` | `gen` plus the assemble-and-re-parse gate and `tests/test_validate.py` |
| `host-test` | host cc | build and run the native tests with ASan+UBSan |
| `qemu-test` | `aarch64-linux-gnu-gcc`, `qemu-aarch64-static` | build `mcbench` static for AArch64 and run `verify --fake-dev --variants all` under qemu |
| `all` | cross `$(CC)` from the Yocto SDK | `gen` plus cross-compile `mcbench` |
| `clean` | | |

`all` assumes the SDK environment is sourced and is the only target that produces a shipped binary. `qemu-test` uses the distro cross compiler, which is a different toolchain; it is a correctness check, never a build product. Build target code with `-O2 -Wall -Wextra -Werror`. Host tests additionally with `-fsanitize=address,undefined -fno-sanitize-recover=all`.

Off-board toolchain, all distro packages: `python3` (stdlib only), a host cc, `binutils-aarch64-linux-gnu`, `gcc-aarch64-linux-gnu`, `libc6-dev-arm64-cross`, `qemu-user-static`.

`scripts/board_env.sh` holds the board parameters as empty variable defines and documents the required kernel/boot setup. `scripts/run_on_device.sh` sources it, copies `build/mcbench` to `$BOARD:/tmp/`, runs it with the given arguments, and copies any `--out` file back. It does nothing else.
