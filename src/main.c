/* mcbench. Phase A implements `info` and `list` and nothing else. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/utsname.h>
#include <time.h>
#include <unistd.h>

#include "timing.h"
#include "uio.h"
#include "variants.h"

#ifndef GIT_SHA
#define GIT_SHA "unknown"
#endif

static void usage(void)
{
    fputs("mcbench info [--uio /dev/uioN --map M | --fake-dev BYTES]\n"
          "mcbench list [--variants SUBSTR]\n", stderr);
}

/* CNTFRQ_EL0 is programmed by firmware and is occasionally wrong. Every
 * number in the report scales with it, so check it against a clock that is
 * independently maintained before trusting it. */
static int check_timer(void)
{
    uint64_t f = ticks_per_sec();
    if (f == 0) {
        fprintf(stderr, "timer frequency reads as zero\n");
        return -1;
    }
    struct timespec a, b;
    uint64_t t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &a);
    t0 = now_ticks();
    struct timespec nap = {0, 20 * 1000 * 1000};
    nanosleep(&nap, 0);
    t1 = now_ticks();
    clock_gettime(CLOCK_MONOTONIC, &b);

    double wall = (double)(b.tv_sec - a.tv_sec)
                + (double)(b.tv_nsec - a.tv_nsec) / 1e9;
    double measured = (double)(t1 - t0) / (double)f;
    double err = (measured - wall) / wall;
    printf("  timer            %s @ %llu Hz (%.2f%% vs CLOCK_MONOTONIC)\n",
           TIMER_NAME, (unsigned long long)f, err * 100.0);
    if (err > 0.01 || err < -0.01) {
        fprintf(stderr, "timer frequency disagrees with CLOCK_MONOTONIC by "
                        "%.2f%%; results would scale with it\n", err * 100.0);
        return -1;
    }
    return 0;
}

static int cmd_info(int argc, char **argv)
{
    const char *uio = 0;
    long fake = 0;
    int map = 0;

    for (int i = 0; i < argc; i++) {
        if (!strcmp(argv[i], "--uio") && i + 1 < argc)            uio = argv[++i];
        else if (!strcmp(argv[i], "--map") && i + 1 < argc)       map = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--fake-dev") && i + 1 < argc)  fake = atol(argv[++i]);
        else { usage(); return 2; }
    }

    struct utsname u;
    uname(&u);
    printf("mcbench %s\n", GIT_SHA);
    printf("  kernel           %s %s\n", u.sysname, u.release);
    printf("  machine          %s\n", u.machine);
    printf("  cpus online      %ld\n", sysconf(_SC_NPROCESSORS_ONLN));
    printf("  page size        %ld\n", sysconf(_SC_PAGESIZE));
    printf("  variants         %zu\n", n_variants);
    int rc = check_timer();

    if (uio || fake) {
        struct devwin w;
        int r = uio ? devwin_open_uio(&w, uio, map)
                    : devwin_open_fake(&w, (size_t)fake);
        if (r < 0)
            return 1;
        printf("  device source    %s\n", w.source);
        printf("  window           %zu bytes at %p\n", w.size, w.base);
        printf("  guard pages      PROT_NONE either side of the window\n");
        if (!strcmp(w.source, "fake"))
            fputs("NOTE: fake device. Nothing measured here says anything "
                  "about the real mapping.\n", stderr);
        devwin_close(&w);
    }
    return rc < 0 ? 1 : 0;
}

static int cmd_list(int argc, char **argv)
{
    const char *filter = 0;
    for (int i = 0; i < argc; i++) {
        if (!strcmp(argv[i], "--variants") && i + 1 < argc) filter = argv[++i];
        else { usage(); return 2; }
    }
    size_t shown = 0;
    printf("%-34s %-4s %-7s %-7s %6s %6s %6s %5s\n",
           "name", "dir", "dev", "ram", "block", "look", "group", "regs");
    for (size_t i = 0; i < n_variants; i++) {
        const struct variant *v = &variants[i];
        if (filter && !strstr(v->name, filter)) continue;
        printf("%-34s %-4s %-7s %-7s %6d %6d %6d %5d\n",
               v->name, v->dir == DIR_RD ? "rd" : "wr",
               v->dev_kind, v->ram_kind, v->block, v->lookahead,
               v->group, v->need);
        shown++;
    }
    printf("%zu of %zu variants\n", shown, n_variants);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc < 2) { usage(); return 2; }
    if (!strcmp(argv[1], "info")) return cmd_info(argc - 2, argv + 2);
    if (!strcmp(argv[1], "list")) return cmd_list(argc - 2, argv + 2);
    usage();
    return 2;
}
