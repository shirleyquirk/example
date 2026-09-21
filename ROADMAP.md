# ROADMAP — uio-memcpy-bench

Each phase ends with a **STOP**. The agent summarises what it built and waits for review. "Human runs" means the agent does not touch the board in that step unless explicitly told to.

---

## Phase 0: Skeleton and toolchain

**Build**
- Repo layout per SPEC §11, `NOTES.md` with empty "Assumptions" and "Proposals" sections, and the Makefile.
- `src/main.c` implementing only `--info` and `--list` (with the list empty for now).
- `src/uio.c`: open the UIO device, read the map size from sysfs, mmap, unmap. No device accesses yet.
- `scripts/run_on_device.sh`.

**Acceptance**
- `make` cross-builds warning-free with `-Werror`.
- Human runs `mcbench --info --uio … --map …` on the board. The output shows the correct map size, CNTFRQ, and kernel version.

**STOP**

---

## Phase 1: Harness, head/tail, baselines

**Build**
- `src/devio.h`: D6 accessors.
- `src/headtail.c` per SPEC §4.1.
- `tests/test_headtail.c`, plus a `make host-test` target that runs it.
- `src/baselines.c`: `base_u8`, `base_u64`, `control_glibc`.
- The full harness per SPEC §7: layout and guards, process setup, verification, timing, sweeps, CSV output.
- Variant table currently populated only with the baselines.

**Acceptance**
- `make host-test` passes the exhaustive head/tail check.
- Human runs `--verify-only` on the board for both directions: all pass, no SIGBUS.
- Human runs a short timing run of the baselines plus `--control`.
  - `control_glibc` RAM→RAM throughput is plausible for an A53.
  - p90/median ≤ 1.2 for the majority of rows.
  - `base_u64` beats `base_u8` at sizes ≥ 64 B.

**STOP**

---

## Phase 2: Generator and validator

**Build**
- `gen/` per SPEC §6: parameter space, feasibility filter, op-list model, `.S` renderer, table emitter, validator.
- `tests/test_validate.py`, with negative tests that must all be rejected.
- Makefile: `gen` runs the generator and validator. `all` depends on `gen`. Any validator failure fails the build.
- Optional: qemu-user functional test, if `qemu-aarch64` is present.

**Acceptance**
- The validator passes on every generated variant, and every negative test is rejected.
- The generator prints the list of skipped combinations. The variant count is roughly 80–100.
- Human reviews the rendered `.S` for 3 or 4 variants: at least one `batch`, one `pipe`, one X-register, and one `l4*`.
- Human runs `--verify-only --variants all` on the board: all pass.

**STOP**

---

## Phase 3: Sweep and analysis

**Build**
- `scripts/analyze.py` per SPEC §9.

**Run** (human, on the board)
1. Size sweep, all variants and baselines, both directions.
2. Offset sweep, baselines plus the top 10 per direction (the agent derives this list from run 1).

**Acceptance**
- `report.md` answers every item in SPEC §9.
- The noise check shows no systematic issue, or the issue is explained.

**STOP.** Human decides whether phase 4 or 5 happens.

---

## Phase 4 (gated): Second-tier axes

This phase only happens if the human approves it, and only for axes the phase 3 data justifies. For each axis, the agent writes a one-paragraph justification citing the phase 3 numbers before implementing it.

Candidates:
- `STNP` on the RAM side for the read direction (avoid L1/L2 fill on large copies). Speculation: A53 handling of the non-temporal hint is unverified.
- `PRFM` on the RAM side for the write direction.
- PMU cycle counting via `perf_event_open` user access. This requires the human to set `kernel.perf_user_access=1`; the agent never runs `sysctl`.
- Alternative head/tail strategies, if small sizes dominate the real workload.

**STOP**

---

## Phase 5 (gated): Extract the winner

- Produce a standalone `uio_copy.h` + `uio_copy.S`: the recommended variant per direction, and a size-threshold dispatch if the data supports one.
- Include a standalone test reusing the head/tail host test and a board verify mode.
- No other changes.

**STOP**
