/* Execute every generated body RAM->RAM and check it.
 *
 * This is the dynamic half of the correctness story. It cannot see
 * Device-memory alignment faults -- no emulator models those, which is why
 * gen/validate.py is the alignment gate -- but it does see everything that
 * only shows up when the code actually runs:
 *
 *   - wrong bytes, wrong order, wrong count
 *   - a callee-saved register destroyed (poison_call)
 *   - an access one byte outside the copy (PROT_NONE guard page)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

typedef void (*body_fn)(void *, const void *, unsigned long);
struct btest { const char *name; unsigned group; unsigned block; int dir;
               body_fn fn; };
extern const struct btest btests[];
extern const size_t n_btests;

int poison_call(body_fn fn, void *dst, const void *src, unsigned long n);

/* A mapping whose last usable byte is immediately followed by PROT_NONE, so a
   copy that runs one byte long faults instead of quietly passing. */
static unsigned char *g_end_src, *g_end_dst;

static unsigned char *guarded_region(size_t bytes)
{
    size_t pg = (size_t)getpagesize();
    size_t n = ((bytes + pg - 1) / pg) * pg;
    unsigned char *m = mmap(NULL, n + pg, PROT_READ | PROT_WRITE,
                            MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (m == MAP_FAILED) { perror("mmap"); exit(2); }
    if (mprotect(m + n, pg, PROT_NONE) < 0) { perror("mprotect"); exit(2); }
    return m + n;               /* one past the last usable byte */
}

static unsigned char pat(size_t i) { return (unsigned char)(i * 31u + 17u); }

int main(int argc, char **argv)
{
    const char *filter = argc > 1 ? argv[1] : NULL;
    size_t cap = 1 << 16;
    g_end_src = guarded_region(cap);
    g_end_dst = guarded_region(cap);

    size_t tested = 0, bodies = 0;
    for (size_t b = 0; b < n_btests; b++) {
        const struct btest *t = &btests[b];
        if (filter && !strstr(t->name, filter)) continue;
        bodies++;
        unsigned long ns[10];
        size_t nn = 0, g = t->group, B = t->block;
        ns[nn++] = 0;        ns[nn++] = g;       ns[nn++] = 2 * g;
        ns[nn++] = 3 * g;    ns[nn++] = B;       ns[nn++] = B + g;
        ns[nn++] = 2 * B;    ns[nn++] = 2 * B + g;
        ns[nn++] = 3 * B + 2 * g; ns[nn++] = 4 * B + 3 * g;

        for (size_t k = 0; k < nn; k++) {
            unsigned long n = ns[k];
            if (n > cap - 4096) continue;
            /* Copy ends flush against the guard page on both sides. Both
               pointers land group-aligned because n is a multiple of the
               group and the guard boundary is page-aligned. */
            unsigned char *src = g_end_src - n;
            unsigned char *dst = g_end_dst - n;
            for (unsigned long i = 0; i < n; i++) src[i] = pat(i);
            memset(dst, 0xA5, n);

            int bad = poison_call(t->fn, dst, src, n);
            if (bad) {
                printf("FAIL %s n=%lu: callee-saved register %d destroyed\n",
                       t->name, n, bad);
                return 1;
            }
            for (unsigned long i = 0; i < n; i++) {
                if (dst[i] != pat(i)) {
                    printf("FAIL %s n=%lu: byte %lu is 0x%02x, expected 0x%02x\n",
                           t->name, n, i, dst[i], pat(i));
                    return 1;
                }
            }
            for (unsigned long i = 0; i < n; i++) {
                if (src[i] != pat(i)) {
                    printf("FAIL %s n=%lu: source byte %lu was modified\n",
                           t->name, n, i);
                    return 1;
                }
            }
            tested++;
        }
    }
    printf("ok: %zu bodies x sizes = %zu copies, all correct, "
           "no register damage, no guard-page hits\n", bodies, tested);
    return 0;
}
