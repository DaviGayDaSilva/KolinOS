/*
 * common.c — shared helpers for KolinOS native tools.
 */
#define _POSIX_C_SOURCE 200809L

#include "kolinos.h"

#include <ctype.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Build the SGR escape from the palette index constants in kolinos.h, so the
 * numbers live in exactly one place. */
#define KOLIN_STR_(x) #x
#define KOLIN_STR(x) KOLIN_STR_(x)
#define KOLIN_FG(idx) "\033[38;5;" KOLIN_STR(idx) "m"

void kolin_colours_init(struct kolin_colours *c)
{
    if (isatty(STDOUT_FILENO)) {
        c->primary = KOLIN_FG(KOLIN_COL_PRIMARY);
        c->accent  = KOLIN_FG(KOLIN_COL_ACCENT);
        c->muted   = KOLIN_FG(KOLIN_COL_MUTED);
        c->bold    = "\033[1m";
        c->reset   = "\033[0m";
    } else {
        c->primary = c->accent = c->muted = c->bold = c->reset = "";
    }
}

int kolin_read_line(const char *path, char *buf, size_t len)
{
    FILE *f = fopen(path, "r");
    if (!f)
        return 0;
    if (!fgets(buf, (int)len, f)) {
        fclose(f);
        return 0;
    }
    fclose(f);
    kolin_rstrip(buf);
    return buf[0] != '\0';
}

char *kolin_read_file(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f)
        return NULL;
    size_t cap = 4096, len = 0;
    char *buf = malloc(cap);
    if (!buf) {
        fclose(f);
        return NULL;
    }
    size_t n;
    while ((n = fread(buf + len, 1, cap - len - 1, f)) > 0) {
        len += n;
        if (len + 1 >= cap) {
            cap *= 2;
            char *grown = realloc(buf, cap);
            if (!grown) {
                free(buf);
                fclose(f);
                return NULL;
            }
            buf = grown;
        }
    }
    fclose(f);
    buf[len] = '\0';
    return buf;
}

int kolin_proc_field(FILE *f, const char *key, char *out, size_t len)
{
    size_t k = strlen(key);
    char line[512];
    rewind(f);
    while (fgets(line, sizeof line, f)) {
        if (strncmp(line, key, k) != 0 || line[k] != ':')
            continue;
        const char *v = line + k + 1;
        while (*v == ' ' || *v == '\t')
            v++;
        snprintf(out, len, "%s", v);
        kolin_rstrip(out);
        return out[0] != '\0';
    }
    return 0;
}

void kolin_human_size(unsigned long long bytes, char *out, size_t len)
{
    static const char *unit[] = { "B", "KiB", "MiB", "GiB", "TiB" };
    double v = (double)bytes;
    int i = 0;
    while (v >= 1024.0 && i < 4) {
        v /= 1024.0;
        i++;
    }
    if (i == 0)
        snprintf(out, len, "%llu B", bytes);
    else
        snprintf(out, len, "%.1f %s", v, unit[i]);
}

void kolin_field(const struct kolin_colours *c, const char *label,
                 const char *fmt, ...)
{
    printf("  %s%-13s%s ", c->muted, label, c->reset);
    va_list ap;
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    putchar('\n');
}

char *kolin_rstrip(char *s)
{
    size_t n = strlen(s);
    while (n > 0 && isspace((unsigned char)s[n - 1]))
        s[--n] = '\0';
    return s;
}
