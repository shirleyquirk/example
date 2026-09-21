# ROADMAP — uio-memcpy-bench

Phases A–D need no board. They are developed on an ordinary x86-64 host, with every variant actually executed under `qemu-aarch64-static`. Phase E is first board contact and is deliberately tiny, because by then the same binary has run the same correctness sweep against a fake device — everything except the memory attribute has been tested.

Each phase ends with a **STOP**: the agent summarises what it built, lists anything deviating from the spec, and waits for review. "Human runs" means the agent does not touch the board in that step unless explicitly told to.

**Host tooling required for A–D**, all distro packages: `python3` (stdlib only), a host C compiler with ASan/UBSan, `binutils-aarch64-linux-gnu`, `gcc-aarch64-linux-gnu`, `libc6-dev-arm64-cross`, `qemu-user-static`. No board. The distro cross compiler is a correctness tool only — the shipped binary is still built with the Yocto SDK in phase E.

---

## Phase A: Skeleton, accessors, head/tail

**Build**
- Repo layout per SPEC §11. `NOTES.md` with "Assumptions" and "Proposals". The Makefile with `gen`, `check`, `host-test`, `all`, `clean`.
- `src/devio.h`: D6 accessors, with a host build mode that redirects them to a logging mock.
- `src/headtail.c` per SPEC §4.1, including the packed-struct RAM accesses (SPEC §3.1 — no `memcpy`, no builtins).
- `src/uio.c`: open the UIO device, read the map size from sysfs, mmap, unmap. No device accesses. Plus the `--fake-dev` anonymous-mapping path behind the same interface.
- `src/main.c`: `info` and `list` only.
- `tests/test_headtail.c` and the `host-test` target.
- `scripts/board_env.sh`: every board parameter as an empty variable define, plus the boot/kernel setup the measurements assume (`isolcpus`, `nohz_full`, region idleness, and the `kernel.perf_user_access` note for phase G). The agent never sets any of it.

**Acceptance**
- `make host-test` passes the exhaustive head/tail check for every `Wdev` in the table, clean under ASan and UBSan.
- The head/tail log shows D1–D3 hold for device offsets 0–127 × `n` 0–600.
- `grep` confirms no `memcpy`/`memmove`/`__builtin_mem*` in any copy path.
- No board, no cross-compiler needed.

**STOP**

---

## Phase B: Patterns, harness, fake device, baselines

**Build**
- `src/pattern.c`: the tagged pattern fill/check per SPEC §7.4, with the decoded failure report.
- The harness per SPEC §7: layout with per-test margins and window guards, process setup, the SIGBUS/SIGSEGV handler, the `verify` subcommand, CSV output.
- `src/baselines.c`: `base_u8`, `base_u64`, `control_glibc`.
- `tests/test_harness.c`: run the harness against the fake device and assert the pattern checker catches injected faults — short by one, long by one, displaced by 64, source written, and a copy that reads outside its range.
- `tests/poison.S`: the AAPCS64 register-poisoning call wrapper (SPEC §6.5), used by `verify`.
- The `PROT_NONE` reservation around the window (SPEC §7.2).

**Acceptance**
- `mcbench verify --fake-dev … --variants all` passes natively for the baselines over the full correctness sweep.
- `make qemu-test` builds `mcbench` for AArch64 and runs the same sweep under qemu, passing.
- Every injected fault is caught, and the failure report names the right byte and diagnosis.
- A copy deliberately made to step outside the window faults on the guard page and produces a located SIGSEGV report, not silent corruption.
- Still no board.

**STOP**

---

## Phase C: Generator and validator

**Build**
- `gen/isa.py`: the device and RAM instruction tables per SPEC §5.1, documented so adding a row is the only edit needed.
- `gen/variants.py`: parameter space and feasibility by liveness (SPEC §5.4).
- `gen/emit.py`: op-list model, then `.S` and `variants_table.c` rendered from it.
- `gen/validate.py`: all six checks of SPEC §6.4, including the assemble-and-re-parse gate.
- `tests/test_validate.py`: the negative tests, all of which must be rejected.
- Makefile: `gen` runs generator plus validator; `check` adds the re-parse gate and the negative tests; `all` depends on `gen`.

**Acceptance**
- `make check` passes: every variant simulates correctly over `nbytes` = 0 … 4T+Wdev+3, assembles, and disassembles back to its own model.
- `make qemu-test` passes for **every variant**, both directions, over the full correctness sweep: correct copies, no callee-saved register destroyed, no guard-page fault.
- Every negative test is rejected, including an unguarded `pipe` prologue and aliased `pipe` register sets. The same three defects are also built deliberately and confirmed to fail under qemu, so the static and dynamic gates are each shown to work.
- The generator prints the skipped combinations with reasons. The count is whatever it is.
- Human reviews the rendered `.S` for 3 or 4 variants: at least one `batch`, one `pipe`, one X-register kind, one `l4*`, and one with a non-power-of-two `dev_count`.
- Still no board. At this point every variant has been executed, just not against Device memory.

**STOP**

---

## Phase D: Timing machinery and analysis

**Build**
- The `bench` subcommand per SPEC §7.5: R calibration, samples, min/median/p90, randomised order, incremental flush, ETA.
- `scripts/analyze.py` per SPEC §9, including the distinct-code-path collapsing.

**Acceptance**
- `mcbench bench --fake-dev …` on the host produces a well-formed CSV for the baselines and `control_glibc`, with the fake-device banner and `devsrc=fake`.
- R calibration converges and each sample lands within a sane band of 100 µs.
- `analyze.py` produces a `report.md` from that CSV that answers every SPEC §9 item, and refuses to mix `fake` and `uio` rows.
- The numbers are meaningless; the pipeline is proven. **Still no board.**

**STOP**

---

## Phase E: First board contact

The build finally needs the Yocto SDK. The human fills `scripts/board_env.sh` before this phase and runs everything; the agent touches nothing.

**Build**
- `scripts/run_on_device.sh` per SPEC §11.

**Run** (human, on the board)
1. `mcbench info`.
2. `mcbench verify --variants all --dir both` over the default correctness sweep.

**Acceptance**
- `make all` cross-builds warning-free with `-Werror`.
- `info` shows the correct map size, a `CNTFRQ_EL0` that passes the `CLOCK_MONOTONIC` cross-check, and the kernel version.
- `verify` passes for every variant in both directions with no SIGBUS. Any SIGBUS here is a real finding: it means the validator's alignment model and the hardware disagree — qemu cannot catch that class, by construction — and it stops the phase.

**STOP**

---

## Phase F: Sweeps and report

**Run** (human, on the board)
1. `bench` size sweep, all variants and baselines, both directions, plus `--control`.
2. `bench` offset sweep, baselines plus the top 10 per direction (the agent derives the list from run 1).

**Acceptance**
- `control_glibc` RAM→RAM throughput is plausible for an A53.
- `base_u64` beats `base_u8` at sizes ≥ 64 B.
- p90/median ≤ 1.2 for the majority of rows, or the exceptions are explained.
- `report.md` answers every item in SPEC §9, states the warm-RAM-side measurement condition, and says at which size each axis starts to separate.

**STOP.** Human decides whether phase G or H happens.

---

## Phase G (gated): Second-tier axes

Only for axes the phase F data justifies. For each, the agent writes a one-paragraph justification citing phase F numbers before implementing it. Most of these are now a row in `gen/isa.py` rather than new code.

Candidates:
- `STNP` on the RAM side for the read direction (avoid L1/L2 fill on large copies). Speculation: A53 handling of the non-temporal hint is unverified.
- `PRFM` on the RAM side for the write direction.
- The `saved` register tier (SPEC §4.2), if register pressure is what caps the useful batch size.
- PMU cycle counting via `perf_event_open` user access. Requires the human to set `kernel.perf_user_access=1`; the agent never runs `sysctl`.
- Alternative head/tail strategies, if small sizes dominate the real workload.
- A cold-RAM-side timing mode, if the warm-cache condition looks like it is deciding the winner.

**STOP**

---

## Phase H (gated): Extract the winner

- Produce a standalone `uio_copy.h` + `uio_copy.S`: the recommended variant per direction, and a size-threshold dispatch if the data supports one.
- Include a standalone test reusing the head/tail host test and a board verify mode.
- No other changes.

**STOP**
