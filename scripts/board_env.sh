#!/bin/sh
# Board parameters and environment contract for uio-memcpy-bench.
#
# Fill these in before the first board phase (ROADMAP phase E). Nothing in
# phases A-D reads this file. Source it, or let scripts/run_on_device.sh do it.
#
# This file is data and documentation only. It never changes the board: no
# sysctl, no writes to /sys or /proc, no boot arguments. The setup described
# under "Required board state" is the human's to arrange.

# --- Connection -------------------------------------------------------------

# ssh destination for the board, e.g. "root@192.168.1.50" or an ssh_config host.
BOARD=""

# Where to stage the binary on the board.
BOARD_TMP="/tmp"

# --- Device mapping ---------------------------------------------------------

# UIO character device, e.g. "/dev/uio0".
UIO_DEV=""

# Map index within that device; the size is read from
# /sys/class/uio/uio<N>/maps/map<M>/size at runtime, never hardcoded.
UIO_MAP=""

# Optional. Region size in bytes, for a sanity check against sysfs. Leave empty
# to accept whatever sysfs reports.
UIO_SIZE_EXPECT=""

# --- Benchmark CPU ----------------------------------------------------------

# CPU to pin to. Must be isolated: see "Required board state" below.
BENCH_CPU=""

# --- Build ------------------------------------------------------------------

# Yocto SDK environment script, sourced before `make all`.
# e.g. "/opt/poky/4.0/environment-setup-cortexa53-crypto-poky-linux"
SDK_ENV=""

# --- Optional cross-checks --------------------------------------------------

# Expected CNTFRQ_EL0 in Hz, if known. The harness reads CNTFRQ_EL0 itself and
# cross-checks it against CLOCK_MONOTONIC regardless; this is belt and braces.
CNTFRQ_HZ_EXPECT=""

# Kernel version string recorded with the results. Left empty, the harness
# takes it from uname at runtime.
KERNEL_EXPECT=""

# ----------------------------------------------------------------------------
# Required board state (the human arranges this; the tool only checks it)
# ----------------------------------------------------------------------------
#
# 1. CPU isolation. BENCH_CPU must be isolated at boot:
#
#        isolcpus=<N> nohz_full=<N> rcu_nocbs=<N> irqaffinity=<other cpus>
#
#    isolcpus keeps the scheduler off it, nohz_full stops the periodic tick,
#    rcu_nocbs moves RCU callbacks away, irqaffinity keeps device interrupts
#    off it. Without these, p90/median blows past the 1.2 noise gate and the
#    small-size numbers are tick noise. Verify with /proc/cmdline.
#
# 2. Frequency and idle states. A cpufreq governor that ramps, or deep cpuidle
#    states, add a variable first-sample penalty. Pin the governor to
#    "performance" and restrict cpuidle to a shallow state for the duration.
#    Both are /sys writes and are the human's to make.
#
# 3. The region must be idle. No FPGA logic, no DMA engine, and no other
#    process may touch the reserved region during a run. A concurrent writer
#    does not corrupt the host - it corrupts the measurement and can fail the
#    pattern check in a way that looks like a copy bug.
#
# 4. UIO device permissions. The user running mcbench needs read/write on
#    UIO_DEV. mmap of a no-map reserved region needs nothing else.
#
# 5. Phase G only: PMU user access. `kernel.perf_user_access=1` is required for
#    userspace cycle counting. The human sets it; mcbench never runs sysctl and
#    never writes to /proc/sys.
#
# 6. Nothing else should be running. mlockall(2) is used, so the box needs
#    enough free memory for the RAM buffer to be locked.
