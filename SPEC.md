# SPEC — uio-memcpy-bench

## 1. Purpose

Find the fastest correct way to copy between a **Device-nGnRnE userspace mapping** (UIO, backed by a `no-map` reserved DRAM region) and **normal cacheable RAM** on a Cortex-A53, in both directions, from userspace only.

The deliverable is data plus a recommendation: which instruction pattern wins per direction and size range, and why. This is a measurement tool, not a library.

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

### 2.1 Parameters to fill before Phase 0 (human)

| Name | Value |
|---|---|
| `BOARD` (ssh host) | `<fill>` |
| UIO device | `/dev/uio<fill>` |
| Map index | `<fill>` |
| Region size (bytes) | `<fill>` |
| Isolated CPU for benchmarking | `<fill>` (booted with `isolcpus=`/`nohz_full=`) |
| Yocto SDK environment script | `<fill>` |
| Kernel version on board | `<fill>` |
| Region idle during runs? | Must be **yes**: no FPGA/DMA/other process touching it |

## 3. Device-side access rules (safety-critical)

These apply to every access the harness or any variant makes to the UIO mapping.

- **D1: Naturally aligned.** Every device access of size S bytes is at an address that is a multiple of S. For multi-register instructions (`LDP`, `LD1 {…}`), the address must be a multiple of the **total** bytes transferred by the instruction. This is stricter than the architecture requires, chosen deliberately.
- **D2: In range.** No device byte outside `[dev_ptr, dev_ptr + n)` is ever read or written by a copy function. This includes no over-reads and no "overlapping tail" tricks.
- **D3: Exactly once.** Each device byte in range is accessed exactly once per copy.
- **D4: No forbidden instructions on the device side.** No `PRFM`, `DC *`, `LDNP`/`STNP`, exclusives (`LDXR`/`STXR`/…), atomics, `LDAR`/`STLR`, or any barrier inside a copy function.
- **D5: Window only.** The harness only ever touches the device window defined in §7.2, including guard zones.
- **D6: Accessor discipline.** C code touching the device side does so only through `volatile` fixed-width accessors (`dev_ld8/16/32/64`, `dev_st8/16/32/64`) defined in one header. No `memcpy`, `memset`, or struct copies on device pointers.

## 4. Copy function contract

```c
typedef void (*copy_fn)(void *dst, const void *src, size_t n);
```

- read direction: `src` is device, `dst` is RAM. write direction: the reverse.
- Any `n` ≥ 0 and any alignment of either pointer.
- Each variant is specialised to one direction.
- A copy function = **shared head** (C) + **generated body** (asm) + **shared tail** (C). This is fixed and is not a sweep axis in phases 0–3.

### 4.1 Shared head/tail (`src/headtail.c`)

- **Head:** while the device pointer is not aligned to W (the variant's device instruction width) and bytes remain, do the largest power-of-two access (1/2/4/8) that is aligned at the current device address and fits in the remaining bytes. Device side uses D6 accessors. RAM side uses plain `memcpy` of that size (the RAM side may be unaligned).
- **Tail:** the remaining bytes (< W) are copied with descending aligned power-of-two accesses, same rules.
- If `n` is too small to reach alignment, the head/tail logic alone completes the copy.

### 4.2 Generated body

```c
void body_<id>(void *dst, const void *src, size_t nchunks);
```

- The device pointer is aligned to W on entry. `nchunks` is the number of W-byte chunks.
- The body processes chunks in batches of B while `nchunks ≥ B`, then single chunks. This is a fixed structure (see §6.2).
- Leaf function, no stack frame.
- **AAPCS64:** may clobber `x0–x17`, `v0–v7`, `v16–v31`. Must not touch `x18` (platform register), `x19–x29`, `sp`, or `v8–v15`. That leaves 15 X scratch registers (`x3–x17`) and 24 V registers.

## 5. Variant space (phases 2–3)

### 5.1 Device instruction kind (the RAM side uses the matching instruction)

| id | Device instruction | W (bytes) | Regs per instr |
|---|---|---|---|
| `x8` | `LDR`/`STR Xn` | 8 | 1 X |
| `xp16` | `LDP`/`STP Xn, Xm` | 16 | 2 X |
| `q16` | `LDR`/`STR Qn` | 16 | 1 V |
| `qp32` | `LDP`/`STP Qn, Qm` | 32 | 2 V |
| `l4b64` | `LD1`/`ST1 {4 regs}.16b` | 64 | 4 V |
| `l4d64` | `LD1`/`ST1 {4 regs}.2d` | 64 | 4 V |

`l4b64` vs `l4d64` is deliberate. On non-Gathering memory, element size may determine how the access is split on the bus: `.16b` could become up to 64 byte-sized transactions, while `.2d` becomes 8-byte ones. **This is speculation. How the A53 actually behaves is what we're measuring.** The same uncertainty applies to whether `LDR Q` / `LDP` issue as one transaction or several.

### 5.2 Batch B

B ∈ {1, 2, 4, 8}: the number of device instructions issued back-to-back before their data is consumed (read direction) or before the next group of RAM loads (write direction).

### 5.3 Schedule

- **`batch`:** issue B device loads, then B RAM stores (read). Or B RAM loads, then B device stores (write). Needs B × regs-per-instr registers.
- **`pipe`:** software-pipelined. In steady state, issue the device accesses for batch i+1 while completing batch i. Implement by unrolling ×2 so the two register sets alternate statically, with odd batch counts handled in the epilogue. Needs 2 × B × regs-per-instr registers.

### 5.4 Feasibility

A combination whose register need exceeds the budget (15 X / 24 V) is **not generated**. The generator prints the list of skipped combinations and why. Expected total: roughly 80–100 variants across both directions.

### 5.5 Baselines (hand-written C, `src/baselines.c`)

- `base_u8`: volatile byte loop on the device side.
- `base_u64`: shared head/tail + volatile aligned 8-byte loop.
- `control_glibc`: glibc `memcpy` **RAM→RAM only**, to sanity-check the timing harness. Never pointed at the device.

## 6. Generator (`gen/`)

### 6.1 Pipeline

`variants.py` (parameter space, feasibility) → `emit.py` (builds an **op-list model** per variant, then renders `.S` from it) → `validate.py` (checks the op-list model and lints the rendered `.S`) → outputs `build/gen/variants.S` and `build/gen/variants_table.c`.

The op list is the single source of truth. The `.S` file is rendered from it, never hand-edited.

### 6.2 Fixed body structure

```
prologue          (pipe only: issue first batch's device-side loads / RAM-side loads)
batched loop      while nchunks >= B (pipe: unrolled x2, alternating reg sets)
epilogue          (pipe only: drain the last batch)
single-chunk loop while nchunks >= 1
return
```

Each segment is a straight-line op list with symbolic offsets relative to the current device/RAM pointers. Each op records: side (dev/ram), load/store, byte offset, size, registers, and mnemonic.

### 6.3 Variant table

`variants_table.c` exports:

```c
struct variant { const char *name; int dir; int w; const char *kind; int b; const char *sched; copy_fn fn; };
extern const struct variant variants[]; extern const size_t n_variants;
```

`fn` is a C wrapper, head → `body_<id>` → tail. Names follow the pattern `<dir>_<kind>_b<B>_<sched>`, for example `rd_qp32_b4_pipe`.

### 6.4 Validator (`gen/validate.py`) must check, for every variant

1. **Simulation:** interpret the op-list model for `nchunks` = 0 … 4B+3 and assert that device accesses satisfy D1–D3 relative to a W-aligned base. RAM-side accesses must cover the same byte range exactly once.
2. **Registers:** only permitted registers are used (§4.2), and no register is reused before its value is consumed.
3. **Lint of rendered `.S`:** no forbidden mnemonics (D4), no forbidden registers, and exactly one global symbol per variant.
4. **Build gate:** any failure exits non-zero, and `make` fails.

### 6.5 Host tests

- `tests/test_headtail.c` is built natively on the host with the D6 accessors redefined to log `(addr, size, op)`. For device offsets 0–127 × `n` 0–600 × every W, it asserts D1–D3 and a correct copy.
- `tests/test_validate.py` feeds the validator deliberately broken op lists (misaligned, overlapping, out-of-range, forbidden register) and asserts each one is rejected.
- Optional: if `qemu-aarch64` is available, run every variant RAM→RAM for a size/offset grid and compare against a reference copy. **Note:** qemu does not model Device-memory alignment faults, so the validator is the alignment gate, not qemu.

## 7. Harness (`mcbench`, `src/`)

### 7.1 CLI

```
mcbench --info                      print map size, CNTFRQ_EL0, cpu, kernel, variant count
mcbench --list                      list variant names
mcbench --uio /dev/uioN --map M --cpu C
        [--dir read|write|both] [--variants SUBSTR|all]
        [--sizes LIST|default] [--dev-offsets LIST] [--ram-offsets LIST]
        [--samples N=31] [--seed S] [--max-size BYTES]
        [--verify-only] [--control] --out results.csv
```

No other flags.

### 7.2 Memory layout

- The device window is the UIO map, mmapped at offset `M * pagesize`. The size is read from `/sys/class/uio/uioN/maps/mapM/size`.
- Guards of G = 256 bytes sit at each end. The working area is `[G, size − G)`. The device base for a test is `working_start + dev_offset`, where `working_start` is 4096-aligned.
- The RAM buffer comes from `posix_memalign(4096)` and has guard zones laid out the same way. It is prefaulted with `memset`.
- Refuse to run (exit non-zero with a message) if `max_size + max_offset + 2G` exceeds the window.

### 7.3 Process setup

`sched_setaffinity` to `--cpu`, then `mlockall(MCL_CURRENT | MCL_FUTURE)`. Fail loudly if either fails.

### 7.4 Verification (always runs before timing any combination)

For each (variant, size, dev_off, ram_off):
1. Fill the source with a seeded PRNG pattern and the destination plus guards with a poison pattern. Device-side fill and readback use only D6 aligned 8-byte accessors.
2. Run the copy once.
3. Compare the destination and check that both guards are untouched.

Any failure aborts the whole run, printing the variant, size, and offsets.

### 7.5 Timing

- Timer: `CNTVCT_EL0`, read as `isb; mrs`. Convert with `CNTFRQ_EL0`.
- Each sample: `isb; t0 = cntvct; for (r = 0; r < R; r++) fn(dst, src, n); dsb sy; isb; t1 = cntvct`. The `dsb sy` ensures posted device writes are counted.
- Calibrate R per combination so that each sample lasts ≥ 100 µs.
- Take `--samples` samples. Record min, median, and p90 of ticks per call.
- Combination order is randomised with `--seed`. The seed is written to the CSV.
- Print progress and an ETA to stderr.

### 7.6 Default sweeps

- **Size sweep:** sizes 1–64 (every value), 96, 128, 192, 256, 384, 512, 768, 1K, 1.5K, 2K, 4K, 8K, 16K, 64K, 256K, 1M (clamped to the window). `dev_off = 0`, `ram_off = 0`.
- **Offset sweep:** `dev_off` ∈ {0, 1, 2, 3, 4, 7, 8, 12, 15, 16, 24, 31, 32, 48, 63}, `ram_off` ∈ {0, 5}, sizes {1–64, 4K}. Run this for the baselines and the top 10 variants per direction from the size sweep only.

## 8. Output (`results.csv`)

Columns: `variant, dir, kind, w, b, sched, size, dev_off, ram_off, samples, reps_per_sample, min_ticks, med_ticks, p90_ticks, cntfrq, med_ns, med_MBps, seed, git_sha, kernel, hostname, cpu, timestamp`.

One row per combination. `git_sha` is embedded at build time.

## 9. Analysis (`scripts/analyze.py`)

Input: one or more CSVs. Output: `report.md` containing:
1. Per direction, the top 5 variants by median throughput in each size bucket: ≤64 B, 65–512 B, 513 B–4 KiB, >4 KiB.
2. The effect of W at fixed B/schedule, and of B at fixed kind/schedule, as small tables.
3. `l4b64` vs `l4d64` head-to-head.
4. Small-size (1–64 B) cost versus `base_u64`.
5. A noise check: flag rows where p90/median > 1.2.
6. A recommendation: best variant per direction per bucket, and whether one variant is within 5% of the best everywhere.

Optional PNG plots if matplotlib is available.

## 10. Non-goals

Kernel code; changing mapping attributes; UIO→UIO or RAM→RAM optimisation; prefetch and non-temporal variants (phase 4 only, gated); head/tail strategy variants (phase 4 only, gated); auto-tuning or search algorithms; multi-threaded copies; any other CPU or SoC.

## 11. Repo layout

```
CLAUDE.md SPEC.md ROADMAP.md NOTES.md Makefile
gen/      variants.py emit.py validate.py gen_variants.py
src/      main.c uio.c uio.h timing.h devio.h headtail.c headtail.h baselines.c
tests/    test_headtail.c test_validate.py
scripts/  run_on_device.sh analyze.py
build/    (generated; not committed)
```

Makefile targets: `all` (cross-compile; assumes the SDK environment is sourced, uses `$(CC)`), `gen`, `host-test`, `clean`. Build with `-O2 -Wall -Wextra -Werror`.

`scripts/run_on_device.sh` copies `build/mcbench` to `$BOARD:/tmp/`, runs it with the given arguments, and copies any `--out` file back. It does nothing else.
