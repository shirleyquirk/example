/* The timer, behind two functions with exactly two implementations.
 *
 * On the board: CNTVCT_EL0, read after an ISB so the read cannot drift
 * earlier past the work being timed, converted with CNTFRQ_EL0.
 * Anywhere else: CLOCK_MONOTONIC, so the timing path is testable off-board.
 * The second exists for phase D and for nothing else.
 */
#ifndef TIMING_H
#define TIMING_H

#include <stdint.h>
#include <time.h>

#if defined(__aarch64__)

static inline uint64_t now_ticks(void)
{
    uint64_t t;
    /* ISB first: the counter read must not be speculated before the work. */
    __asm__ volatile("isb; mrs %0, cntvct_el0" : "=r"(t) :: "memory");
    return t;
}

static inline uint64_t ticks_per_sec(void)
{
    uint64_t f;
    __asm__ volatile("mrs %0, cntfrq_el0" : "=r"(f));
    return f;
}

#define TIMER_NAME "CNTVCT_EL0"

#else

static inline uint64_t now_ticks(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static inline uint64_t ticks_per_sec(void) { return 1000000000ull; }

#define TIMER_NAME "CLOCK_MONOTONIC"

#endif

#endif /* TIMING_H */
