# SETUP — reproducing the off-board environment

Phases A–D of the roadmap need no board and no AArch64 machine. This is
everything required, written down because the work happens in throwaway
containers and a toolchain you cannot rebuild in one command is a toolchain
you have lost.

## One command

```sh
make deps        # needs root; Debian/Ubuntu
make check       # negative tests, then generate + validate
make qemu-test   # execute every generated body
```

`make deps` installs:

| package | used for |
|---|---|
| `python3` | the generator. Stdlib only — no pip, no venv |
| `build-essential` | host compiler for the native tests |
| `binutils-aarch64-linux-gnu` | `as` and `objdump` for the assemble-and-re-parse gate |
| `gcc-aarch64-linux-gnu` | cross-compiling the body tests and `mcbench` for emulation |
| `libc6-dev-arm64-cross` | AArch64 headers and libc, needed by the above |
| `qemu-user-static` | executing AArch64 binaries on an x86-64 host |

Nothing else. No CMake, no pip packages, no container image.

`make check-tools` verifies the set without installing anything, and every
gate names the package it needs and fails rather than skipping itself. A gate
that quietly disappears when the container is recycled is worse than no gate.

## What this toolchain is not

`gcc-aarch64-linux-gnu` is **not** the Yocto SDK. Different libc, different
tuning, different everything that matters for a shipped binary. It is a
correctness tool only. `make all` — the only target that produces the binary
that runs on the board — uses `$(CC)` from the sourced SDK environment, and
that is phase E.

Likewise qemu: it does not model Device-nGnRnE memory, so it cannot see the
alignment faults that are the whole safety story. `gen/validate.py` is the
alignment gate. qemu catches what only shows up when code runs — wrong bytes,
destroyed callee-saved registers, accesses that leave the buffer.

## Board setup

`scripts/board_env.sh` holds every board parameter as an empty variable define,
alongside the boot and kernel state the measurements depend on (`isolcpus`,
`nohz_full`, governor, region idleness). Fill it in before phase E. Nothing in
phases A–D reads it.

## Gate summary

| gate | make target | catches | blind to |
|---|---|---|---|
| op-list model | `check` | D1/D2/D3, byte-exact copy, register liveness | renderer bugs — it checks the model, not the code |
| negative tests | `check` | a gate that has stopped working | — |
| assemble + re-parse | `check` | renderer bugs, bad operands, encoding failures | anything about running it |
| qemu + poison + guard pages | `qemu-test` | wrong results, AAPCS64 violations, escapes from the buffer | Device-memory alignment, timing |

Current state: 1532 variants, 13/13 injected defects caught, 15320 copies
executed correctly under emulation.
