#ifndef UIO_H
#define UIO_H

#include <stddef.h>

struct devwin {
    void *base;          /* first usable byte of the window */
    size_t size;         /* usable bytes */
    void *reservation;   /* PROT_NONE reservation, for unmapping */
    size_t reserved;
    const char *source;  /* "uio" or "fake" -- goes in the CSV */
};

/* Map UIO device `path`, map index `map`. Returns 0 on success. */
int devwin_open_uio(struct devwin *w, const char *path, int map);

/* An anonymous mapping of `size` bytes standing in for the device, so the
 * harness runs on any machine. Never times anything real. */
int devwin_open_fake(struct devwin *w, size_t size);

void devwin_close(struct devwin *w);

#endif /* UIO_H */
