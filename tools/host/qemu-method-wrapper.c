/* qemu-method-wrapper.c — let a foreign-architecture APT run under qemu-user.
 *
 * APT does not just run itself: it forks helper binaries (http, https, file,
 * gpgv, store, copy...) from /usr/lib/apt/methods/. Inside an aarch64 chroot on
 * an x86_64 kernel those helpers cannot be exec'd — there is no binfmt_misc
 * entry, and a chroot cannot register one because /proc/sys is read-only in a
 * container. The result is the misleading error:
 *
 *     E: Method http has died unexpectedly!
 *     E: Method /usr/lib/apt/methods/http did not start correctly
 *
 * A shell wrapper cannot fix this either: the shell inside the chroot is itself
 * aarch64, so the wrapper would need the very mechanism that is missing. The
 * wrapper therefore has to be a *native* (x86_64) static binary, which is what
 * this is.
 *
 * Installed once per helper name (http, https, file, gpgv, ...) in a directory
 * passed to APT as Dir::Bin::Methods. argv[0] selects which aarch64 helper to
 * run through qemu; all arguments are forwarded unchanged.
 *
 * Build (host, x86_64):
 *   gcc -O2 -static -o qemu-method-wrapper qemu-method-wrapper.c
 */
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/stat.h>

#define QEMU "/usr/bin/qemu-aarch64-static"
#define MAX_ARGS 256

/* Real aarch64 binaries live in two places: transport methods under
 * /usr/lib/apt/methods/, and signature verifiers (sqv, gpgv) under /usr/bin/.
 * Suffixes are tried in order so the real binary can be parked next to the
 * wrapper without colliding with it: "sqv" would be the wrapper itself, so the
 * real one lives at "sqv.real" and is found on the second try. */
static const char *const SEARCH_DIRS[] = {
    "/usr/lib/apt/methods",
    "/usr/bin",
    NULL,
};
static const char *const NAME_SUFFIXES[] = {
    ".real",
    "",
    NULL,
};

int main(int argc, char **argv)
{
    /* basename(argv[0]) selects the helper. This binary is installed once per
     * helper, and the install name may carry a "-qemu" suffix (sqv-qemu,
     * gpgv-qemu) so it does not shadow the real binary in the same directory. */
    const char *slash = strrchr(argv[0], '/');
    const char *name = slash ? slash + 1 : argv[0];

    char base[256];
    int n = snprintf(base, sizeof base, "%s", name);
    if (n < 0 || (size_t)n >= sizeof base) {
        fprintf(stderr, "qemu-method-wrapper: nome longo demais\n");
        return 100;
    }
    size_t blen = strlen(base);
    if (blen > 5 && strcmp(base + blen - 5, "-qemu") == 0)
        base[blen - 5] = '\0';

    char helper[512];
    int found = 0;
    for (int s = 0; NAME_SUFFIXES[s] && !found; s++) {
        for (int d = 0; SEARCH_DIRS[d] && !found; d++) {
            int k = snprintf(helper, sizeof helper, "%s/%s%s",
                             SEARCH_DIRS[d], base, NAME_SUFFIXES[s]);
            if (k <= 0 || (size_t)k >= sizeof helper)
                continue;
            /* Never resolve to ourselves, or the wrapper execs itself forever.
             * APT hardcodes /usr/bin/sqv, so the wrapper is often installed
             * exactly where the real binary would be; comparing device and
             * inode catches the collision even across differing paths. */
            struct stat cand, self;
            if (access(helper, X_OK) != 0)
                continue;
            if (stat(helper, &cand) == 0 && stat("/proc/self/exe", &self) == 0
                    && cand.st_dev == self.st_dev && cand.st_ino == self.st_ino)
                continue;
            found = 1;
        }
    }
    if (!found) {
        fprintf(stderr, "qemu-method-wrapper: binário real '%s' não encontrado "
                        "(tentei %s em %s e %s)\n",
                base, NAME_SUFFIXES[0], SEARCH_DIRS[0], SEARCH_DIRS[1]);
        return 100;
    }

    /* argv for qemu: qemu -L / <helper> <original argv[1..]> */
    char *newargv[MAX_ARGS + 4];
    int i = 0;
    newargv[i++] = (char *)QEMU;
    newargv[i++] = (char *)"-L";
    newargv[i++] = (char *)"/";
    newargv[i++] = helper;
    for (int a = 1; a < argc && i < MAX_ARGS + 3; a++)
        newargv[i++] = argv[a];
    newargv[i] = NULL;

    execv(QEMU, newargv);
    /* execv only returns on failure. */
    fprintf(stderr, "qemu-method-wrapper: não foi possível executar %s para '%s': %s\n",
            QEMU, base, strerror(errno));
    return 100;
}
