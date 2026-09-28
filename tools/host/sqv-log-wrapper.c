/* sqv-log-wrapper.c — diagnostic: log how APT invokes sqv, then run the real one.
 *
 * Standalone `sqv --keyring K --cleartext --output O FILE` verifies our
 * InRelease and prints the fingerprint, yet the same binary fails with exit
 * 123 when APT forks it. The difference must be in the arguments, so record
 * them and forward to the real sqv via qemu.
 *
 * Native (x86_64) static for the same reason as qemu-method-wrapper: inside an
 * aarch64 chroot a shell wrapper cannot be executed.
 *
 * Build: gcc -O2 -static -o sqv-log-wrapper sqv-log-wrapper.c
 */
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/stat.h>

#define QEMU "/usr/bin/qemu-aarch64-static"
#define REAL_SQV "/usr/lib/apt/bin-real/sqv"
#define LOGFILE "/tmp/sqv-args.log"

int main(int argc, char **argv)
{
    FILE *log = fopen(LOGFILE, "a");
    if (log) {
        fprintf(log, "argc=%d", argc);
        for (int i = 0; i < argc; i++)
            fprintf(log, " [%d]=%s", i, argv[i]);
        fprintf(log, "\n");
        fclose(log);
    }

    char *newargv[264];
    int i = 0;
    newargv[i++] = (char *)QEMU;
    newargv[i++] = (char *)"-L";
    newargv[i++] = (char *)"/";
    newargv[i++] = (char *)REAL_SQV;
    for (int a = 1; a < argc && i < 262; a++)
        newargv[i++] = argv[a];
    newargv[i] = NULL;

    execv(QEMU, newargv);
    fprintf(stderr, "sqv-log-wrapper: exec falhou: %s\n", strerror(errno));
    return 123;
}
