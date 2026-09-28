/*
 * kolinos-hw — native hardware detection for KolinOS.
 *
 * Reports CPU, memory, storage, thermal and load information on ARM64 Linux.
 * Written in C on purpose: this is the part of the system that should keep
 * working when little else does. A shell plus awk implementation costs
 * several megabytes of RSS and a fork per field — the wrong trade on the
 * low-RAM ARM64 phones KolinOS targets. This reads /proc and /sys directly
 * and needs no interpreter, no external command and no libc beyond the
 * essentials.
 *
 * Every source is optional. On Termux/proot, in a container, or on a kernel
 * without a given subsystem, the corresponding field is omitted rather than
 * filled with a guessed value.
 */
#define _POSIX_C_SOURCE 200809L

#include "kolinos.h"

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/utsname.h>
#include <unistd.h>

/* --- CPU ---------------------------------------------------------------- */

static void cpu_model(char *buf, size_t len)
{
    /* ARM64 kernels are inconsistent here: mainline uses "model name", some
     * vendor trees "Hardware", others "Processor". */
    static const char *keys[] = { "model name", "cpu model", "Hardware", "Processor", NULL };
    FILE *f = fopen("/proc/cpuinfo", "r");
    if (!f)
        return;
    for (int i = 0; keys[i]; i++)
        if (kolin_proc_field(f, keys[i], buf, len)) {
            fclose(f);
            return;
        }
    fclose(f);
}

static long cpu_count(void)
{
    long n = 0;
    char line[512];
    FILE *f = fopen("/proc/cpuinfo", "r");
    if (f) {
        while (fgets(line, sizeof line, f))
            if (strncmp(line, "processor", 9) == 0 && line[9] == ':')
                n++;
        fclose(f);
    }
    /* sched_getaffinity is authoritative under containers, which restrict
     * the visible CPUs; /proc/cpuinfo can over-report there. */
    long affinity = sysconf(_SC_NPROCESSORS_ONLN);
    if (affinity > 0 && (n == 0 || affinity < n))
        return affinity;
    return n > 0 ? n : affinity;
}

/* Big.LITTLE SoCs report several distinct "CPU part" ids. Counting them
 * distinguishes a homogeneous 8-core VM from a real phone SoC without
 * hardcoding any known part number. */
static int cpu_clusters(void)
{
    char parts[16][64];
    int nparts = 0, i;
    FILE *f = fopen("/proc/cpuinfo", "r");
    if (!f)
        return 0;
    char line[512];
    while (fgets(line, sizeof line, f)) {
        if (strncmp(line, "CPU part", 8) != 0 || line[8] != ':')
            continue;
        const char *v = line + 9;
        while (*v == ' ' || *v == '\t')
            v++;
        /* Bound the copy to the table cell: a /proc line cannot be longer
         * than the buffer it was read into, but the compiler cannot prove it. */
        char val[64];
        snprintf(val, sizeof val, "%.63s", v);
        kolin_rstrip(val);
        int seen = 0;
        for (i = 0; i < nparts; i++)
            if (strcmp(parts[i], val) == 0)
                seen = 1;
        if (!seen && nparts < 16)
            snprintf(parts[nparts++], sizeof parts[0], "%s", val);
    }
    fclose(f);
    return nparts;
}

static void show_cpu(const struct kolin_colours *c)
{
    char model[256] = "";
    cpu_model(model, sizeof model);
    if (model[0])
        kolin_field(c, "CPU", "%s", model);

    long n = cpu_count();
    if (n > 0) {
        int clusters = cpu_clusters();
        if (clusters > 1)
            kolin_field(c, "Núcleos", "%ld (big.LITTLE, %d clusters)", n, clusters);
        else
            kolin_field(c, "Núcleos", "%ld", n);
    }
}

/* --- memory ------------------------------------------------------------- */

static void show_memory(const struct kolin_colours *c)
{
    FILE *f = fopen("/proc/meminfo", "r");
    if (!f)
        return;
    char line[256];
    long total = 0, avail = 0, swap_total = 0, swap_free = 0, kb;
    while (fgets(line, sizeof line, f)) {
        if (sscanf(line, "MemTotal: %ld kB", &kb) == 1)
            total = kb;
        else if (sscanf(line, "MemAvailable: %ld kB", &kb) == 1)
            avail = kb;
        else if (sscanf(line, "SwapTotal: %ld kB", &kb) == 1)
            swap_total = kb;
        else if (sscanf(line, "SwapFree: %ld kB", &kb) == 1)
            swap_free = kb;
    }
    fclose(f);

    if (total > 0 && avail > 0) {
        long used = total - avail;
        kolin_field(c, "Memória", "%ld MiB de %ld MiB em uso (%ld%%)",
                    used / 1024, total / 1024, (used * 100) / total);
    } else if (total > 0) {
        /* MemAvailable only appeared in Linux 3.14; older kernels get the
         * total alone rather than a wrong "used" figure. */
        kolin_field(c, "Memória", "%ld MiB", total / 1024);
    }
    if (swap_total > 0)
        kolin_field(c, "Swap", "%ld MiB de %ld MiB livres",
                    swap_free / 1024, swap_total / 1024);
}

/* --- storage ------------------------------------------------------------ */

static void show_storage(const struct kolin_colours *c)
{
    /* Report every real filesystem, not just "/": on a phone the interesting
     * one is usually a small data or SD partition.
     *
     * Two filters matter here, both learned from a container host: a bind
     * mount of a single file (/etc/hosts, /dev/termination-log) is not a
     * disk, and one filesystem bind-mounted at twenty paths is still one
     * filesystem. So: directories only, and deduplicated by st_dev. */
    FILE *f = fopen("/proc/mounts", "r");
    if (!f)
        return;
    struct { dev_t dev; } seen[64];
    int nseen = 0, shown = 0;
    char dev[256], mnt[256], type[64];
    while (fscanf(f, "%255s %255s %63s %*s %*s %*s", dev, mnt, type) == 3) {
        /* Skip pseudo filesystems: their sizes are synthetic. */
        if (strncmp(dev, "/dev/", 5) != 0)
            continue;
        struct stat st;
        if (stat(mnt, &st) != 0 || !S_ISDIR(st.st_mode))
            continue;
        for (int i = 0; i < nseen; i++)
            if (seen[i].dev == st.st_dev)
                goto next;
        if (nseen < 64)
            seen[nseen++].dev = st.st_dev;

        struct statvfs vfs;
        if (statvfs(mnt, &vfs) != 0)
            continue;
        unsigned long long bsize = vfs.f_frsize ? vfs.f_frsize : vfs.f_bsize;
        unsigned long long total = bsize * vfs.f_blocks;
        unsigned long long avail = bsize * vfs.f_bavail;
        if (total == 0)
            continue;
        char ht[32], ha[32];
        kolin_human_size(total, ht, sizeof ht);
        kolin_human_size(avail, ha, sizeof ha);
        kolin_field(c, shown == 0 ? "Disco" : "", "%s em %s (%s livre)",
                    ht, mnt, ha);
        shown++;
next:;
    }
    fclose(f);
}

/* --- thermal ------------------------------------------------------------ */

static void show_thermal(const struct kolin_colours *c)
{
    /* Thermal zones are the one place a phone reports temperature without
     * root. Values are millidegrees Celsius. */
    DIR *d = opendir("/sys/class/thermal");
    if (!d)
        return;
    struct dirent *e;
    int shown = 0;
    while ((e = readdir(d))) {
        if (strncmp(e->d_name, "thermal_zone", 12) != 0)
            continue;
        char path[512], type[128] = "";
        long milli;
        snprintf(path, sizeof path, "/sys/class/thermal/%s/type", e->d_name);
        kolin_read_line(path, type, sizeof type);
        snprintf(path, sizeof path, "/sys/class/thermal/%s/temp", e->d_name);
        FILE *f = fopen(path, "r");
        if (!f)
            continue;
        int ok = fscanf(f, "%ld", &milli) == 1;
        fclose(f);
        /* Bounds are physical plausibility, not a whitelist: some zones
         * return 0 or absurd values on virtual hardware. */
        if (!ok || milli == 0 || milli < -100000 || milli > 200000)
            continue;
        kolin_field(c, shown == 0 ? "Térmico" : "", "%s: %.1f°C",
                    type[0] ? type : e->d_name, (double)milli / 1000.0);
        if (++shown >= 4) /* an ARM SoC has many zones; a few tell the story */
            break;
    }
    closedir(d);
}

/* --- uptime / load ------------------------------------------------------ */

static void show_uptime(const struct kolin_colours *c)
{
    FILE *f = fopen("/proc/uptime", "r");
    if (f) {
        double up;
        if (fscanf(f, "%lf", &up) == 1) {
            long s = (long)up;
            kolin_field(c, "Uptime", "%ldh%02ldm", s / 3600, (s % 3600) / 60);
        }
        fclose(f);
    }
    f = fopen("/proc/loadavg", "r");
    if (f) {
        double a, b, d;
        if (fscanf(f, "%lf %lf %lf", &a, &b, &d) == 3)
            kolin_field(c, "Carga", "%.2f %.2f %.2f", a, b, d);
        fclose(f);
    }
}

/* --- entry point -------------------------------------------------------- */

static void usage(const char *p)
{
    fprintf(stderr,
            "uso: %s [--json]\n"
            "  --json   saída legível por máquina (JSON em uma linha)\n",
            p);
}

static void json_escape(const char *s)
{
    for (; *s; s++) {
        unsigned char ch = (unsigned char)*s;
        if (ch == '"' || ch == '\\')
            printf("\\%c", ch);
        else if (ch < 0x20)
            printf("\\u%04x", ch);
        else
            putchar(ch);
    }
}

int main(int argc, char **argv)
{
    int json = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--json") == 0) {
            json = 1;
        } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            usage(argv[0]);
            return 0;
        } else if (strcmp(argv[i], "-v") == 0 || strcmp(argv[i], "--version") == 0) {
            printf("kolinos-hw %s\n", KOLINOS_VERSION);
            return 0;
        } else {
            usage(argv[0]);
            return 2;
        }
    }

    struct kolin_colours c;
    kolin_colours_init(&c);

    struct utsname u;
    int have_uname = uname(&u) == 0;

    if (json) {
        printf("{\"tool\":\"kolinos-hw\",\"version\":\"%s\"", KOLINOS_VERSION);
        if (have_uname) {
            printf(",\"kernel\":\"");
            json_escape(u.release);
            printf("\",\"arch\":\"");
            json_escape(u.machine);
            printf("\"");
        }
        printf("}\n");
        return 0;
    }

    printf("%sKolinOS%s hardware\n", c.bold, c.reset);
    if (have_uname) {
        kolin_field(&c, "Máquina", "%s", u.machine);
        kolin_field(&c, "Kernel", "%s %s", u.sysname, u.release);
    }
    show_cpu(&c);
    show_memory(&c);
    show_storage(&c);
    show_thermal(&c);
    show_uptime(&c);
    putchar('\n');
    return 0;
}
