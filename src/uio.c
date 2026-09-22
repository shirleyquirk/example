/* Mapping the device window.
 *
 * The window is mapped MAP_FIXED inside a PROT_NONE reservation, so the pages
 * on either side of it are unmapped rather than whatever the allocator put
 * there. An access that escapes the window then faults immediately, at the
 * offending address, instead of silently corrupting a neighbouring mapping.
 * That is the difference between "stop and report" being a rule and being a
 * hope (CLAUDE.md, SPEC 7.2).
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include "uio.h"

static size_t page(void) { return (size_t)sysconf(_SC_PAGESIZE); }

static size_t round_up(size_t v, size_t a) { return (v + a - 1) / a * a; }

/* Reserve size + 2 guard pages as PROT_NONE and hand back where the window
 * should go. The caller maps over it with MAP_FIXED. */
static int reserve(struct devwin *w, size_t size, void **slot)
{
    size_t pg = page();
    size_t body = round_up(size, pg);
    w->reserved = body + 2 * pg;
    w->reservation = mmap(NULL, w->reserved, PROT_NONE,
                          MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (w->reservation == MAP_FAILED) {
        fprintf(stderr, "reserving %zu bytes: %s\n", w->reserved, strerror(errno));
        return -1;
    }
    *slot = (char *)w->reservation + pg;
    return 0;
}

static long read_sysfs_size(const char *devpath, int map)
{
    const char *n = strrchr(devpath, 'o');   /* .../uioN -> N */
    char path[256];
    if (!n || !n[1]) {
        fprintf(stderr, "cannot parse a uio index out of '%s'\n", devpath);
        return -1;
    }
    snprintf(path, sizeof path, "/sys/class/uio/uio%s/maps/map%d/size", n + 1, map);
    FILE *f = fopen(path, "r");
    if (!f) {
        fprintf(stderr, "open %s: %s\n", path, strerror(errno));
        return -1;
    }
    unsigned long long sz = 0;
    int got = fscanf(f, "%lli", (long long *)&sz);   /* sysfs prints hex 0x... */
    fclose(f);
    if (got != 1) {
        fprintf(stderr, "could not read a size from %s\n", path);
        return -1;
    }
    return (long)sz;
}

int devwin_open_uio(struct devwin *w, const char *path, int map)
{
    memset(w, 0, sizeof *w);
    long size = read_sysfs_size(path, map);
    if (size <= 0)
        return -1;

    int fd = open(path, O_RDWR | O_SYNC);
    if (fd < 0) {
        fprintf(stderr, "open %s: %s\n", path, strerror(errno));
        return -1;
    }

    void *slot;
    if (reserve(w, (size_t)size, &slot) < 0) { close(fd); return -1; }

    /* UIO selects the map by the mmap offset: map M lives at M * pagesize. */
    void *p = mmap(slot, (size_t)size, PROT_READ | PROT_WRITE,
                   MAP_SHARED | MAP_FIXED, fd, (off_t)map * (off_t)page());
    close(fd);
    if (p == MAP_FAILED) {
        fprintf(stderr, "mmap %s map %d: %s\n", path, map, strerror(errno));
        munmap(w->reservation, w->reserved);
        return -1;
    }
    w->base = p;
    w->size = (size_t)size;
    w->source = "uio";
    return 0;
}

int devwin_open_fake(struct devwin *w, size_t size)
{
    memset(w, 0, sizeof *w);
    void *slot;
    if (reserve(w, size, &slot) < 0)
        return -1;
    void *p = mmap(slot, size, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
    if (p == MAP_FAILED) {
        fprintf(stderr, "fake device mmap: %s\n", strerror(errno));
        munmap(w->reservation, w->reserved);
        return -1;
    }
    w->base = p;
    w->size = size;
    w->source = "fake";
    return 0;
}

void devwin_close(struct devwin *w)
{
    if (w->reservation)
        munmap(w->reservation, w->reserved);
    memset(w, 0, sizeof *w);
}
