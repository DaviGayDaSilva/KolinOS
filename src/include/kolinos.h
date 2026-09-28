/*
 * kolinos.h — shared declarations for KolinOS native tools.
 *
 * Small enough to stay readable, but with one rule: no dependency outside
 * libc. These binaries ship inside a rootfs that must boot and run when the
 * system is degraded, so linking against a JSON library or a colour library
 * would work against the reason they are written in C at all.
 */
#ifndef KOLINOS_H
#define KOLINOS_H

#include <stddef.h>
#include <stdio.h>

#define KOLINOS_VERSION "1.0.0"

/* Brand palette: 256-colour indices, kept in sync with
 * config/branding/palette.txt and VERSION (KOLIN_COLOR_*). */
#define KOLIN_COL_PRIMARY 99
#define KOLIN_COL_ACCENT  44
#define KOLIN_COL_MUTED   245
#define KOLIN_COL_OK      76
#define KOLIN_COL_WARN    214
#define KOLIN_COL_ERR     203

/* Terminal colours. Empty strings when stdout is not a tty, so piping to a
 * file never leaves escape sequences behind. */
struct kolin_colours {
    const char *primary, *accent, *muted, *bold, *reset;
};

void kolin_colours_init(struct kolin_colours *c);

/* Read the first line of a file into buf, stripping the newline.
 * Returns 1 on success, 0 when the file is missing or empty. */
int kolin_read_line(const char *path, char *buf, size_t len);

/* Read a whole file, tolerating a missing trailing newline. Returns a
 * malloc'd string the caller must free, or NULL. */
char *kolin_read_file(const char *path);

/* Parse a /proc-style "Key: value" line matched by key (colon required).
 * Returns 1 and fills out on success. */
int kolin_proc_field(FILE *f, const char *key, char *out, size_t len);

/* 1024-based human size ("1.4 GiB"), the same convention as 'du -h'. */
void kolin_human_size(unsigned long long bytes, char *out, size_t len);

/* Print "  label   value" with aligned label column. */
void kolin_field(const struct kolin_colours *c, const char *label,
                 const char *fmt, ...);

/* Strip trailing whitespace in place and return the string. */
char *kolin_rstrip(char *s);

#endif /* KOLINOS_H */
