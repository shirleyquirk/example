/* The shared head and tail: the parts of a copy that are not the generated
 * body. Both ends reduce to one rule, applied in one loop:
 *
 *   take the largest power-of-two access of 1, 2, 4 or 8 bytes that is
 *   naturally aligned at the current *device* address and fits in what
 *   remains.
 *
 * "Naturally aligned at the device address" is D1. The RAM side may be
 * unaligned and is accessed with a packed-struct load/store, which is one
 * unaligned LDR/STR on AArch64 -- never memcpy, never a builtin (SPEC 3.1).
 *
 * The head runs that loop until the device pointer reaches the alignment the
 * generated body needs; the tail runs it until nothing is left. If n is too
 * small to reach alignment, the head consumes the whole copy and the body is
 * never called.
 */
#include "variants.h"
#include "devio.h"

/* Largest 1/2/4/8 access that is aligned at `dev` and fits in `rem`. */
static inline unsigned step_size(uintptr_t dev, size_t rem)
{
    unsigned s = 8;
    while (s > 1 && (s > rem || (dev & (s - 1)) != 0))
        s >>= 1;
    return s;
}

/* One step, in whichever direction. Device side through the D6 accessors,
 * RAM side through the packed accessors. */
static inline void step_copy(void *dst, const void *src, unsigned s, int dir)
{
    if (dir == DIR_RD) {
        switch (s) {
        case 8: ram_st64(dst, dev_ld64(src)); break;
        case 4: ram_st32(dst, dev_ld32(src)); break;
        case 2: ram_st16(dst, dev_ld16(src)); break;
        default: ram_st8(dst, dev_ld8(src)); break;
        }
    } else {
        switch (s) {
        case 8: dev_st64(dst, ram_ld64(src)); break;
        case 4: dev_st32(dst, ram_ld32(src)); break;
        case 2: dev_st16(dst, ram_ld16(src)); break;
        default: dev_st8(dst, ram_ld8(src)); break;
        }
    }
}

void ht_copy(void *dst, const void *src, size_t n,
             int dir, unsigned wdev, unsigned group, body_fn body)
{
    unsigned char *d = dst;
    const unsigned char *s = src;
    size_t rem = n;

    /* The device pointer is whichever side the direction says it is. */
    #define DEVP ((uintptr_t)(dir == DIR_RD ? (const void *)s : (const void *)d))

    /* Head: reach the alignment the body needs. */
    while (rem != 0 && (DEVP & (uintptr_t)(wdev - 1)) != 0) {
        unsigned sz = step_size(DEVP, rem);
        step_copy(d, s, sz, dir);
        d += sz; s += sz; rem -= sz;
    }

    /* Body: whole groups only. The body advances both pointers itself. */
    if (body != 0 && rem >= group) {
        size_t nbody = rem - (rem % group);
        body(d, s, (unsigned long)nbody);
        d += nbody; s += nbody; rem -= nbody;
    }

    /* Tail: the same rule again, to zero. */
    while (rem != 0) {
        unsigned sz = step_size(DEVP, rem);
        step_copy(d, s, sz, dir);
        d += sz; s += sz; rem -= sz;
    }

    #undef DEVP
}
