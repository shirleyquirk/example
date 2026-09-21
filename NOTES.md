# NOTES — uio-memcpy-bench

## Assumptions

Unspecified details, decided by picking the simplest option. Recorded here rather than asked about, per CLAUDE.md.

- **Host environment for phases A–D.** x86-64, `python3` stdlib, a host cc with ASan/UBSan, `binutils-aarch64-linux-gnu`, `gcc-aarch64-linux-gnu`, `libc6-dev-arm64-cross`, `qemu-user-static`. All distro packages. `make check` and `make qemu-test` name the missing package and fail rather than skipping themselves.
- **The distro cross compiler is not the SDK.** Different libc and tuning. It builds correctness binaries only; `make all` with the Yocto SDK builds the thing that ships.
- **`--sizes` / `--dev-offsets` / `--ram-offsets` grammar.** Comma-separated decimal integers, with optional `K`/`M` suffixes (powers of 1024), and `a-b` ranges meaning every value inclusive. `default` selects the sweep from SPEC §7.6.
- **`--variants SUBSTR`** matches by plain substring on the variant name, case-sensitive. `all` selects everything.
- **Baseline rows in the CSV** leave `dev_kind`, `wdev`, `dev_count`, `t`, `ram_kind`, `sched` and `regtier` empty. `control_glibc` also leaves `dir` empty, since RAM→RAM has no direction.
- **`dev_count` default list** is `{1, 2, 3, 4, 6, 8, 12, 16}`, filtered by feasibility. Non-powers of two are included because the loop is a byte comparison, so they cost nothing to support.
- **Register tier default** is `caller` (SPEC §4.2). The `saved` tier exists in the generator from phase C but is not swept until phase G.
- **Pattern `mix`.** A 64-bit multiply-xor-shift hash of `(global_byte_offset, seed, buffer_id)`, truncated to 6 bits. Any cheap avalanching hash does; the requirement is only that it is not periodic in any instruction width.
- **Per-test margin size** is 256 bytes, matching the window guard size and comfortably larger than the widest instruction (64 B) plus the 8-byte fill envelope.
- **`verify` double pass** uses `seed` and `~seed`.
- **Timer abstraction.** `now_ticks()`/`ticks_per_sec()` have exactly two implementations: `CNTVCT_EL0`/`CNTFRQ_EL0` on AArch64, `clock_gettime(CLOCK_MONOTONIC)` elsewhere. The second exists only so phase D is testable off-board.

## Proposals

Things deliberately not built. Raise to the human before implementing any of them.

- **Cold-RAM-side timing.** Every `bench` number has a warm RAM side because R repeats the copy back to back. A mode that evicts the RAM buffer between calls (or times a single call against a much coarser clock) would measure the other case. Deferred to phase G, where it is the natural partner of the `STNP` axis.
- **Recording the generator input hash in the CSV** alongside `git_sha`, so results can be tied to an exact instruction table even across uncommitted edits.
- **A `--dry-run` cost estimate** printing the combination count and projected wall time before a sweep starts. The ETA already covers this once a run is going.
- **Checking D3 on hardware.** Not possible: a byte written twice is indistinguishable from a byte written once. If it ever mattered, an FPGA-side transaction counter on the reserved region would be the only way to see it.
- **Widening the RAM instruction table with `LDNP`/`STNP` and `PRFM`.** Phase G, gated on phase F data.

- **Timing under qemu.** Meaningless, and `bench --fake-dev` under emulation would produce a plausible-looking CSV. The `devsrc` column and the stderr banner are the only guard; a hard refusal to bench when `/proc/self/maps` smells of qemu was considered and judged too clever.

## Open questions for the human

- `CNTFRQ_EL0` for this board: stated to exist in an earlier conversation, not available in this session. The harness reads it at runtime and cross-checks it, so nothing is blocked; paste it into `CNTFRQ_HZ_EXPECT` in `scripts/board_env.sh` if you want the extra check.
