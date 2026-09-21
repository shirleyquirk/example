# CLAUDE.md — uio-memcpy-bench

Read `SPEC.md` and `ROADMAP.md` in full before doing anything.

## How to work

- **One roadmap phase at a time.** At the end of each phase: stop, summarise what you built, list anything deviating from the spec, and wait for human review. Do not start the next phase unprompted.
- **Build exactly what the spec says.** No extra CLI flags, config files, plugin systems, logging frameworks, abstractions "for later", or features not listed. If you think something is missing, write it under "Proposals" in `NOTES.md` and carry on without it.
- **Unspecified details:** pick the simplest option, record it under "Assumptions" in `NOTES.md`, and continue. Only stop to ask if the choice affects device safety (SPEC §3).
- **Dependencies:** target code is C11 + GNU assembler (AArch64). Host tooling is Python 3 **stdlib only**. `matplotlib` is permitted only in `scripts/analyze.py`, behind a try/except import, and plots are optional output. One `Makefile`. No CMake, no Meson, no pip packages.
- **Style:** boring, short, readable. Every piece of architecture-specific code (AAPCS64 register rules, Device-memory rules, barriers) gets a one-line comment saying *why*. All code is human-reviewed before it ships.

## Device safety — non-negotiable

- You do **not** run anything on the board unless the human explicitly says so for the current phase. When permitted, run only via `scripts/run_on_device.sh`.
- Never use `/dev/mem`. Never write to `/sys` or `/proc`. Never run `sysctl`. Never reboot, flash, modify boot arguments, or touch device-tree/U-Boot.
- All device-side (UIO mapping) accesses must obey SPEC §3 rules D1–D6. Any generated variant that fails the validator (SPEC §6.4) must not be built into the binary. The build must fail rather than silently drop a variant.
- If anything suggests an access outside the mapped window, stop and report. Do not work around it.

## Definitions used everywhere

- **Device side:** the UIO mmap (Device-nGnRnE memory).
- **RAM side:** the ordinary heap buffer.
- **read direction:** UIO → RAM. **write direction:** RAM → UIO.
