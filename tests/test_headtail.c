/* Exhaustive head/tail check, run natively under ASan and UBSan.
 *
 * Every device access the head or tail makes is logged, so D1, D2 and D3 are
 * asserted directly rather than inferred. The generated body is replaced by a
 * stub that logs one access per chunk at the body's own width -- the real
 * body's internals are gen/validate.py's problem, but its *contract* (the
 * device pointer is aligned, the byte count is a whole number of groups) is
 * this test's problem.
 */
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "variants.h"
#include "devio.h"

#define MAXN   600
#define MAXOFF 128
#define PAD    256

static unsigned char devbuf[PAD + MAXOFF + MAXN + PAD];
static unsigned char rambuf[PAD + MAXOFF + MAXN + PAD];

/* Access log for the copy currently under test. */
static struct { uintptr_t addr; unsigned size; char op; } log[8 * MAXN];
static size_t nlog;
static uintptr_t dev_lo, dev_hi;      /* the range this copy may touch */
static const char *ctx = "";

static void fail(const char *why, uintptr_t a, unsigned sz)
{
    printf("FAIL %s: %s at +%ld size %u\n", ctx, why, (long)(a - dev_lo), sz);
    exit(1);
}

void devio_log(const volatile void *p, unsigned size, char op)
{
    uintptr_t a = (uintptr_t)p;
    if (a % size)                                  /* D1 */
        fail("unaligned device access", a, size);
    if (a < dev_lo || a + size > dev_hi)           /* D2 */
        fail("device access outside the copy", a, size);
    assert(nlog < sizeof log / sizeof log[0]);
    log[nlog].addr = a; log[nlog].size = size; log[nlog].op = op;
    nlog++;
}

/* Stand-in for a generated body: copies nbytes and logs one device access per
 * wdev-sized chunk, which is what the real body issues. */
static unsigned stub_wdev;
static int stub_dir;
static void stub_body(void *dst, const void *src, unsigned long nbytes)
{
    const void *devp = (stub_dir == DIR_RD) ? src : dst;
    assert(((uintptr_t)devp % stub_wdev) == 0 && "body entered unaligned");
    assert((nbytes % stub_wdev) == 0 && "body given a partial chunk");
    for (unsigned long i = 0; i < nbytes; i += stub_wdev)
        devio_log((const unsigned char *)devp + i, stub_wdev, 'x');
    unsigned char *d = dst;
    const unsigned char *s = src;
    for (unsigned long i = 0; i < nbytes; i++) d[i] = s[i];
}

static void check_exactly_once(size_t n)
{
    static unsigned char touched[MAXOFF + MAXN + PAD];
    memset(touched, 0, sizeof touched);
    for (size_t i = 0; i < nlog; i++)
        for (unsigned k = 0; k < log[i].size; k++) {
            size_t off = (size_t)(log[i].addr - dev_lo) + k;
            if (touched[off]++)                      /* D3 */
                fail("device byte touched twice", dev_lo + off, 1);
        }
    for (size_t i = 0; i < n; i++)
        if (!touched[i])
            fail("device byte never touched", dev_lo + i, 1);
}

static unsigned char pat(size_t i) { return (unsigned char)(i * 131u + 29u); }

static void one(int dir, unsigned wdev, unsigned group,
                unsigned devoff, unsigned ramoff, size_t n, int use_body)
{
    char name[128];
    snprintf(name, sizeof name, "dir=%d wdev=%u group=%u devoff=%u ramoff=%u n=%zu%s",
             dir, wdev, group, devoff, ramoff, n, use_body ? "" : " (no body)");
    ctx = name;

    unsigned char *dev = devbuf + PAD + devoff;
    unsigned char *ram = rambuf + PAD + ramoff;
    dev_lo = (uintptr_t)dev;
    dev_hi = dev_lo + n;
    nlog = 0;

    memset(devbuf, 0xDD, sizeof devbuf);
    memset(rambuf, 0xA5, sizeof rambuf);
    unsigned char *srcbuf = (dir == DIR_RD) ? dev : ram;
    unsigned char *dstbuf = (dir == DIR_RD) ? ram : dev;
    for (size_t i = 0; i < n; i++) srcbuf[i] = pat(i);

    stub_wdev = wdev; stub_dir = dir;
    ht_copy(dstbuf, srcbuf, n, dir, wdev, group, use_body ? stub_body : 0);

    for (size_t i = 0; i < n; i++)
        if (dstbuf[i] != pat(i)) {
            printf("FAIL %s: byte %zu is 0x%02x, expected 0x%02x\n",
                   name, i, dstbuf[i], pat(i));
            exit(1);
        }
    check_exactly_once(n);
}

int main(void)
{
    static const unsigned widths[] = {8, 16, 32, 64};
    unsigned long cases = 0;

    for (int dir = 0; dir <= 1; dir++)
        for (size_t wi = 0; wi < 4; wi++)
            for (size_t gi = wi; gi < 4; gi++) {
                unsigned wdev = widths[wi], group = widths[gi];
                if (group % wdev) continue;
                for (unsigned devoff = 0; devoff < MAXOFF; devoff++)
                    for (size_t n = 0; n <= MAXN; n++) {
                        one(dir, wdev, group, devoff, (unsigned)(n % 7), n, 1);
                        cases++;
                    }
                /* Same grid with no body at all: the head/tail must complete
                   the whole copy on its own. */
                for (unsigned devoff = 0; devoff < 16; devoff++)
                    for (size_t n = 0; n <= 200; n++) {
                        one(dir, wdev, group, devoff, 3, n, 0);
                        cases++;
                    }
            }

    printf("ok: %lu head/tail cases, D1-D3 hold and every copy is correct\n",
           cases);
    return 0;
}
