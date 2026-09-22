/* D6: every C-level access to the UIO mapping goes through these and nothing
 * else. No memcpy, no memset, no struct copies on a device pointer.
 *
 * `volatile` is what stops the compiler merging, splitting, duplicating or
 * eliding an access. On Device-nGnRnE memory each of those would be a bug:
 * merging breaks nG, duplication breaks D3, and a split of an 8-byte access
 * into two 4-byte ones changes what the endpoint sees.
 *
 * Only 1, 2, 4 and 8 byte widths exist here. Anything wider is a generated
 * body's job, in assembly, where the instruction is chosen deliberately.
 */
#ifndef DEVIO_H
#define DEVIO_H

#include <stdint.h>

#ifdef HOST_MOCK_DEVIO
/* Host builds redirect every device access through a log so the head/tail
 * tests can assert D1-D3 directly instead of inferring them. */
void devio_log(const volatile void *addr, unsigned size, char op);
#define DEVIO_NOTE(p, n, o) devio_log((p), (n), (o))
#else
#define DEVIO_NOTE(p, n, o) ((void)0)
#endif

#define DEVIO_ACCESSORS(bits, type)                                          \
    static inline type dev_ld##bits(const volatile void *p)                  \
    {                                                                        \
        DEVIO_NOTE(p, (bits) / 8, 'r');                                      \
        return *(const volatile type *)p;                                    \
    }                                                                        \
    static inline void dev_st##bits(volatile void *p, type v)                \
    {                                                                        \
        DEVIO_NOTE(p, (bits) / 8, 'w');                                      \
        *(volatile type *)p = v;                                             \
    }

DEVIO_ACCESSORS(8,  uint8_t)
DEVIO_ACCESSORS(16, uint16_t)
DEVIO_ACCESSORS(32, uint32_t)
DEVIO_ACCESSORS(64, uint64_t)

#undef DEVIO_ACCESSORS

/* The RAM side of a head/tail step. Packed and may_alias so the compiler
 * emits one unaligned LDR/STR -- AArch64 allows those on Normal memory -- and
 * so we never call memcpy or a builtin in a copy path (SPEC 3.1). */
#define RAMIO_ACCESSORS(bits, type)                                          \
    struct ram##bits { type v; } __attribute__((packed, may_alias));         \
    static inline type ram_ld##bits(const void *p)                           \
    {                                                                        \
        return ((const struct ram##bits *)p)->v;                             \
    }                                                                        \
    static inline void ram_st##bits(void *p, type v)                         \
    {                                                                        \
        ((struct ram##bits *)p)->v = v;                                      \
    }

RAMIO_ACCESSORS(8,  uint8_t)
RAMIO_ACCESSORS(16, uint16_t)
RAMIO_ACCESSORS(32, uint32_t)
RAMIO_ACCESSORS(64, uint64_t)

#undef RAMIO_ACCESSORS

#endif /* DEVIO_H */
