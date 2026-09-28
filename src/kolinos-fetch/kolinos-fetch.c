/*
 * kolinos-fetch — KolinOS system summary (the distribution's own "fetch").
 *
 * This is the native replacement for the shell version of kolinos-info. It
 * reads the same sources (/etc/os-release, /etc/kolinos/version,
 * /etc/kolinos/branding/logo.txt) but does the whole job in one process
 * instead of spawning sed, awk, dpkg-query and uname, which matters on the
 * low-RAM ARM64 targets and inside proot, where every fork is expensive.
 *
 * The distro identity is deliberately read from the real files rather than
 * compiled in: a single binary then reports the correct values whatever the
 * build configuration was, and no rebuild is needed to change the codename.
 */
#define _POSIX_C_SOURCE 200809L

#include "kolinos.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/utsname.h>
#include <unistd.h>

/* One parsed "KEY=value" pair from os-release, with quotes stripped. */
struct kv {
    char key[64];
    char val[512];
};

static int kv_get(const struct kv *tbl, int n, const char *key, char *out, size_t len)
{
    for (int i = 0; i < n; i++)
        if (strcmp(tbl[i].key, key) == 0) {
            snprintf(out, len, "%s", tbl[i].val);
            return 1;
        }
    return 0;
}

/* Parse an os-release / version file: KEY=value or KEY="value", '#' comments
 * and blank lines ignored. Returns the number of pairs stored. */
static int parse_kv(const char *path, struct kv *tbl, int max)
{
    char *text = kolin_read_file(path);
    if (!text)
        return 0;
    int n = 0;
    char *save = NULL;
    for (char *line = strtok_r(text, "\n", &save); line && n < max;
         line = strtok_r(NULL, "\n", &save)) {
        kolin_rstrip(line);
        char *p = line;
        while (*p == ' ' || *p == '\t')
            p++;
        if (*p == '#' || *p == '\0')
            continue;
        char *eq = strchr(p, '=');
        if (!eq)
            continue;
        *eq = '\0';
        char *val = eq + 1;
        /* Shell-style quoting: strip one layer of matching quotes. */
        size_t vlen = strlen(val);
        if (vlen >= 2 && ((val[0] == '"' && val[vlen - 1] == '"') ||
                          (val[0] == '\'' && val[vlen - 1] == '\''))) {
            val[vlen - 1] = '\0';
            val++;
        }
        snprintf(tbl[n].key, sizeof tbl[n].key, "%s", p);
        snprintf(tbl[n].val, sizeof tbl[n].val, "%s", val);
        n++;
    }
    free(text);
    return n;
}

/* Count installed dpkg packages by walking the status database. Reading
 * /var/lib/dpkg/status directly avoids forking dpkg-query, whose startup
 * alone dwarfs the rest of this program. Only "install ok installed" stanzas
 * count, matching 'dpkg-query -W'. */
static int count_packages(void)
{
    FILE *f = fopen("/var/lib/dpkg/status", "r");
    if (!f)
        return -1;
    char line[512];
    int n = 0, want_pkg = 0;
    while (fgets(line, sizeof line, f)) {
        if (line[0] == '\n') {
            want_pkg = 0;
            continue;
        }
        if (strncmp(line, "Package:", 8) == 0) {
            want_pkg = 1;
            continue;
        }
        if (want_pkg && strncmp(line, "Status:", 7) == 0) {
            if (strstr(line, "install ok installed"))
                n++;
            want_pkg = 0;
        }
    }
    fclose(f);
    return n;
}

static void show_logo(const struct kolin_colours *c)
{
    char *logo = kolin_read_file("/etc/kolinos/branding/logo.txt");
    if (!logo)
        return;
    printf("%s%s%s", c->primary, logo, c->reset);
    free(logo);
}

/* Resolve a uid through /etc/passwd directly.
 *
 * getpwuid() would pull in glibc's NSS at runtime, which a statically linked
 * binary cannot rely on — the linker warns about exactly this. Reading the
 * file is also what a minimal system wants: no nsswitch, no LDAP, no
 * libnss_* modules, one fopen. */
static int passwd_lookup(unsigned uid, char *out, size_t len)
{
    FILE *f = fopen("/etc/passwd", "r");
    if (!f)
        return 0;
    char line[512];
    while (fgets(line, sizeof line, f)) {
        /* name:passwd:uid:gid:gecos:home:shell */
        char name[128];
        unsigned u;
        if (sscanf(line, "%127[^:]:%*[^:]:%u:",
                   name, &u) == 2 && u == uid) {
            fclose(f);
            /* Explicit precision: `name` is larger than the callers' buffers. */
            snprintf(out, len, "%.63s", name);
            return 1;
        }
    }
    fclose(f);
    return 0;
}

int main(int argc, char **argv)
{
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            printf("uso: %s [--no-logo]\n", argv[0]);
            return 0;
        }
        if (strcmp(argv[i], "-v") == 0 || strcmp(argv[i], "--version") == 0) {
            printf("kolinos-fetch %s\n", KOLINOS_VERSION);
            return 0;
        }
    }

    struct kolin_colours c;
    kolin_colours_init(&c);

    static struct kv os[64], kol[64];
    int nos = parse_kv("/etc/os-release", os, 64);
    int nkol = parse_kv("/etc/kolinos/version", kol, 64);

    char name[512] = "KolinOS", ver[128] = "?", codename[128] = "?";
    kv_get(os, nos, "NAME", name, sizeof name);
    kv_get(os, nos, "VERSION_ID", ver, sizeof ver);
    /* VERSION_CODENAME is lower-case; the display form is capitalised. */
    if (kv_get(os, nos, "VERSION_CODENAME", codename, sizeof codename) && codename[0])
        codename[0] = (char)toupper((unsigned char)codename[0]);

    show_logo(&c);

    printf("%s%s%s %s%s (%s%s%s)\n",
           c.bold, c.primary, name, ver, c.reset,
           c.accent, codename, c.reset);
    printf("  %s─────────────────────────────%s\n", c.muted, c.reset);

    char debian[128] = "";
    kv_get(kol, nkol, "DEBIAN_SUITE", debian, sizeof debian);

    char line[512];
    snprintf(line, sizeof line, "%s %s (%s)", name, ver, codename);
    kolin_field(&c, "SO", "%s", line);
    if (debian[0])
        kolin_field(&c, "Base", "Debian %s", debian);

    char id[64] = "kolinos", idlike[64] = "debian";
    kv_get(os, nos, "ID", id, sizeof id);
    kv_get(os, nos, "ID_LIKE", idlike, sizeof idlike);
    kolin_field(&c, "ID", "%s  (ID_LIKE=%s)", id, idlike);

    struct utsname u;
    if (uname(&u) == 0) {
        kolin_field(&c, "Arquitetura", "%s", u.machine);
        kolin_field(&c, "Kernel", "%s %s", u.sysname, u.release);
    }

    /* Prefer /etc/hostname: under proot/chroot the hostname syscall returns
     * the Android host's name, which would misrepresent the system. */
    char host[256];
    if (!kolin_read_line("/etc/hostname", host, sizeof host))
        snprintf(host, sizeof host, "?");
    kolin_field(&c, "Hostname", "%s", host);

    /* USER/LOGNAME are usually set; when they are not (a minimal proot login,
     * a scripted chroot), resolve the real uid through the passwd database
     * instead of printing a bare number. */
    char user[64];
    const char *p = getenv("USER");
    if (!p || !*p)
        p = getenv("LOGNAME");
    if (p && *p) {
        snprintf(user, sizeof user, "%s", p);
    } else if (!passwd_lookup((unsigned)getuid(), user, sizeof user)) {
        snprintf(user, sizeof user, "uid%u", (unsigned)getuid());
    }
    kolin_field(&c, "Usuário", "%s", user);

    const char *shell = getenv("SHELL");
    kolin_field(&c, "Shell", "%s", shell && *shell ? shell : "/bin/sh");

    int pkgs = count_packages();
    if (pkgs >= 0)
        kolin_field(&c, "Pacotes", "%d (dpkg)", pkgs);

    /* Memory and uptime come from the native path; share /proc parsing with
     * kolinos-hw by reading the two fields we need here directly. */
    FILE *f = fopen("/proc/meminfo", "r");
    if (f) {
        long kb;
        char l[256];
        while (fgets(l, sizeof l, f))
            if (sscanf(l, "MemTotal: %ld kB", &kb) == 1) {
                kolin_field(&c, "Memória", "%ld MiB", kb / 1024);
                break;
            }
        fclose(f);
    }

    char build[128] = "";
    if (kv_get(kol, nkol, "BUILD_DATE", build, sizeof build) && build[0])
        kolin_field(&c, "Build", "%s", build);

    putchar('\n');
    return 0;
}
