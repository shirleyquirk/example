#ifndef VARIANTS_H
#define VARIANTS_H

#include <stddef.h>

#define DIR_RD 0        /* device -> RAM */
#define DIR_WR 1        /* RAM -> device */

typedef void (*copy_fn)(void *dst, const void *src, size_t n);
typedef void (*body_fn)(void *dst, const void *src, unsigned long nbytes);

/* head -> generated body -> tail. One copy of the head/tail logic, shared by
 * every variant; see src/headtail.c. */
void ht_copy(void *dst, const void *src, size_t n,
             int dir, unsigned wdev, unsigned group, body_fn body);

struct variant {
    const char *name;
    int dir;
    const char *dev_kind; int wdev;
    const char *ram_kind; int wram;
    int block, lookahead, group;
    const char *regtier; int need;
    copy_fn fn;
};

extern const struct variant variants[];
extern const size_t n_variants;

#endif /* VARIANTS_H */
