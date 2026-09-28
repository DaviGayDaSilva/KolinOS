/*
 * kolinos-bootimg — inspect and validate Android boot images.
 *
 * A boot.img is a header plus page-aligned blobs (kernel, ramdisk, optional
 * second stage and, since header v2, a device tree). No tool in the lean
 * KolinOS rootfs reports what is inside one, and "the file exists and is 24 MiB"
 * says nothing about whether a bootloader could use it. This reads the header
 * and the real file size, and points out the mismatches that would make a
 * device reject the image.
 *
 * Written in C for the same reason as the other native tools: it must run in a
 * rootfs that may be missing python, perl and even a working dynamic loader. It
 * reads only the header, never the whole blob, so it is instant on a 100 MiB
 * image.
 *
 * Header v3/v4 (newer Android devices) have a different layout: a 4096-byte
 * header and no page alignment. Those are reported as unsupported rather than
 * misread — claiming to parse them would be worse than refusing.
 */
#define _POSIX_C_SOURCE 200809L

#include "kolinos.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#define BOOT_MAGIC "ANDROID!"

/* Field offsets, little-endian, identical in v0/v1 (AOSP bootimg.h). The v2
 * fields sit after a packed v1 header: recovery_dtbo_size (1632),
 * recovery_dtbo_offset (1636, uint64), header_size (1644), dtb_size (1648),
 * dtb_addr (1652, uint64). Confirmed against a header produced by the Debian
 * mkbootimg package. */
#define OFF_MAGIC         0
#define OFF_KERNEL_SIZE   8
#define OFF_KERNEL_ADDR   12
#define OFF_RAMDISK_SIZE  16
#define OFF_RAMDISK_ADDR  20
#define OFF_SECOND_SIZE   24
#define OFF_SECOND_ADDR   28
#define OFF_TAGS_ADDR     32
#define OFF_PAGE_SIZE     36
#define OFF_HEADER_VER    40
#define OFF_OS_VER        44
#define OFF_NAME          48
#define OFF_CMDLINE       64
#define OFF_ID            576
#define OFF_EXTRA_CMDLINE 608
#define OFF_DTBO_SIZE     1632
#define OFF_HDR_SIZE      1644
#define OFF_DTB_SIZE      1648
#define OFF_DTB_ADDR      1652

#define HDR_V1_LEN 1632
#define HDR_V2_LEN 1660
#define BUF_LEN    HDR_V2_LEN

struct bootimg {
    uint32_t kernel_size, kernel_addr;
    uint32_t ramdisk_size, ramdisk_addr;
    uint32_t second_size, second_addr;
    uint32_t tags_addr, page_size, header_version, os_version;
    uint32_t dtb_size;
    unsigned long long dtb_addr;
    char name[16];
    char cmdline[512];
    char extra_cmdline[1024];
    char id[64];
    unsigned long long file_size;
    int has_v1, has_v2;
};

static uint32_t u32le(const unsigned char *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static unsigned long long u64le(const unsigned char *p)
{
    return (unsigned long long)u32le(p) | ((unsigned long long)u32le(p + 4) << 32);
}

/* Copy a fixed-width, possibly non-NUL-terminated header string. */
static void copy_fixed(char *dst, size_t dstlen, const unsigned char *src, size_t srclen)
{
    size_t n = 0;
    while (n < srclen && n + 1 < dstlen && src[n] != '\0')
        n++;
    if (n >= dstlen)
        n = dstlen - 1;
    memcpy(dst, src, n);
    dst[n] = '\0';
}

/* Parse into *b, preserving file_size, which the caller sets before calling:
 * this function zeroes the rest of the struct and would otherwise erase it. */
static int parse_header(const unsigned char *h, size_t len, struct bootimg *b)
{
    unsigned long long file_size = b->file_size;
    memset(b, 0, sizeof(*b));
    b->file_size = file_size;
    if (len < HDR_V1_LEN || memcmp(h + OFF_MAGIC, BOOT_MAGIC, 8) != 0)
        return 0;

    b->kernel_size  = u32le(h + OFF_KERNEL_SIZE);
    b->kernel_addr  = u32le(h + OFF_KERNEL_ADDR);
    b->ramdisk_size = u32le(h + OFF_RAMDISK_SIZE);
    b->ramdisk_addr = u32le(h + OFF_RAMDISK_ADDR);
    b->second_size  = u32le(h + OFF_SECOND_SIZE);
    b->second_addr  = u32le(h + OFF_SECOND_ADDR);
    b->tags_addr    = u32le(h + OFF_TAGS_ADDR);
    b->page_size    = u32le(h + OFF_PAGE_SIZE);
    b->header_version = u32le(h + OFF_HEADER_VER);
    b->os_version   = u32le(h + OFF_OS_VER);

    copy_fixed(b->name, sizeof(b->name), h + OFF_NAME, 16);
    copy_fixed(b->cmdline, sizeof(b->cmdline), h + OFF_CMDLINE, 512);
    copy_fixed(b->id, sizeof(b->id), h + OFF_ID, 32);

    b->has_v1 = b->header_version >= 1;
    if (b->has_v1)
        copy_fixed(b->extra_cmdline, sizeof(b->extra_cmdline), h + OFF_EXTRA_CMDLINE, 1024);

    if (b->header_version >= 2) {
        if (len < HDR_V2_LEN)
            return 0;
        b->dtb_size = u32le(h + OFF_DTB_SIZE);
        b->dtb_addr = u64le(h + OFF_DTB_ADDR);
        b->has_v2 = 1;
    }
    return 1;
}

static int is_power_of_two(uint32_t v)
{
    return v != 0 && (v & (v - 1)) == 0;
}

/* Pages needed for a blob of n bytes. Zero-length blobs occupy none. */
static unsigned long long pages_for(uint32_t n, uint32_t page)
{
    return n == 0 ? 0 : ((unsigned long long)n + page - 1) / page;
}

static unsigned long long offset_of(unsigned long long pages, uint32_t page)
{
    return pages * page;
}

int main(int argc, char **argv)
{
    const char *mode, *path;
    struct kolin_colours c;
    unsigned char hdr[BUF_LEN];
    struct bootimg b = {0};
    struct stat st;
    FILE *f;
    size_t got;
    int problems = 0, verbose;

    if (argc != 3 || (strcmp(argv[1], "info") != 0 && strcmp(argv[1], "verify") != 0)) {
        fprintf(stderr,
            "uso: kolinos-bootimg info <boot.img>\n"
            "     kolinos-bootimg verify <boot.img>\n");
        return 2;
    }
    mode = argv[1];
    path = argv[2];
    verbose = strcmp(mode, "info") == 0;
    kolin_colours_init(&c);

    f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "kolinos-bootimg: não foi possível abrir %s\n", path);
        return 2;
    }
    got = fread(hdr, 1, sizeof(hdr), f);
    fclose(f);

    if (stat(path, &st) != 0) {
        fprintf(stderr, "kolinos-bootimg: stat falhou em %s\n", path);
        return 2;
    }
    b.file_size = (unsigned long long)st.st_size;

    if (got < 8 || memcmp(hdr, BOOT_MAGIC, 8) != 0) {
        fprintf(stderr,
            "kolinos-bootimg: %s não é um boot.img Android (magic != \"ANDROID!\")\n"
            "  Esperado: um arquivo cujos 8 primeiros bytes são \"ANDROID!\".\n"
            "  Um kernel Linux cru (vmlinuz) ou uma imagem de disco NÃO são boot.img.\n",
            path);
        return 1;
    }
    if (!parse_header(hdr, got, &b)) {
        fprintf(stderr, "kolinos-bootimg: cabeçalho ilegível em %s\n", path);
        return 1;
    }
    if (b.header_version > 2) {
        fprintf(stderr,
            "kolinos-bootimg: header_version %u não suportado (este leitor cobre v0–v2).\n"
            "  v3/v4 usam cabeçalho de 4096 bytes sem alinhamento por página; lê-los com o\n"
            "  layout v0–v2 produziria números errados, então a leitura é recusada.\n",
            b.header_version);
        return 1;
    }

    /* --- computed layout -------------------------------------------------- */
    unsigned long long k_p = pages_for(b.kernel_size,  b.page_size);
    unsigned long long r_p = pages_for(b.ramdisk_size, b.page_size);
    unsigned long long s_p = pages_for(b.second_size,  b.page_size);
    unsigned long long d_p = b.has_v2 ? pages_for(b.dtb_size, b.page_size) : 0;

    unsigned long long off_ramdisk = offset_of(k_p, b.page_size);
    unsigned long long off_second  = off_ramdisk + offset_of(r_p, b.page_size);
    unsigned long long off_dtb     = off_second  + offset_of(s_p, b.page_size);
    unsigned long long minimal     = off_dtb     + offset_of(d_p, b.page_size);

    if (verbose) {
        printf("%sKolinOS boot.img%s  %s\n", c.bold, c.reset, path);
        kolin_field(&c, "magic",      "ANDROID!");
        kolin_field(&c, "header",     "v%u", b.header_version);
        kolin_field(&c, "page size",  "%u bytes", b.page_size);
        kolin_field(&c, "kernel",     "%u bytes (%llu páginas) @ 0x%08x",
                    b.kernel_size, k_p, b.kernel_addr);
        kolin_field(&c, "ramdisk",    "%u bytes (%llu páginas) @ 0x%08x",
                    b.ramdisk_size, r_p, b.ramdisk_addr);
        if (b.second_size)
            kolin_field(&c, "second", "%u bytes (%llu páginas) @ 0x%08x",
                        b.second_size, s_p, b.second_addr);
        if (b.has_v2)
            kolin_field(&c, "dtb",    "%u bytes (%llu páginas) @ 0x%llx",
                        b.dtb_size, d_p, b.dtb_addr);
        kolin_field(&c, "tags",       "0x%08x", b.tags_addr);
        if (b.name[0])
            kolin_field(&c, "name",   "%s", b.name);
        kolin_field(&c, "cmdline",    "%s", b.cmdline[0] ? b.cmdline : "(vazia)");
        if (b.has_v1 && b.extra_cmdline[0])
            kolin_field(&c, "extra",  "%s", b.extra_cmdline);
        if (b.id[0])
            kolin_field(&c, "id",     "%.32s", b.id);

        printf("\n%slayout%s (offset do primeiro byte de cada blob)\n", c.bold, c.reset);
        kolin_field(&c, "header",   "0 (1 página)");
        kolin_field(&c, "kernel",   "%llu", offset_of(1, b.page_size));
        if (b.ramdisk_size)
            kolin_field(&c, "ramdisk", "%llu", off_ramdisk);
        if (b.second_size)
            kolin_field(&c, "second",  "%llu", off_second);
        if (d_p)
            kolin_field(&c, "dtb",     "%llu", off_dtb);
        kolin_field(&c, "mínimo exigido",    "%llu bytes", minimal);
        kolin_field(&c, "tamanho no arquivo", "%llu bytes", b.file_size);
        printf("\n%sverificação%s\n", c.bold, c.reset);
    }

    /* --- validation ------------------------------------------------------- */
#define CHECK(cond, okmsg, failmsg)                                           \
    do {                                                                      \
        if (cond) {                                                           \
            if (verbose) printf("  [ok]    %s\n", okmsg);                     \
        } else {                                                              \
            printf("  [FALHA] %s\n", failmsg);                                \
            problems++;                                                       \
        }                                                                     \
    } while (0)

#define CHECKF(cond, okmsg, failfmt, ...)                                     \
    do {                                                                      \
        if (cond) {                                                           \
            if (verbose) printf("  [ok]    %s\n", okmsg);                     \
        } else {                                                              \
            printf("  [FALHA] " failfmt "\n", __VA_ARGS__);                   \
            problems++;                                                       \
        }                                                                     \
    } while (0)

    CHECK(is_power_of_two(b.page_size),
          "page size é potência de dois",
          "page size não é potência de dois — nenhum bootloader aceita");
    CHECK(b.kernel_size > 0,
          "kernel presente",
          "kernel_size = 0 — o boot.img não leva kernel");
    CHECK(!b.has_v2 || b.dtb_size > 0,
          "dtb incluída (exigida pelo header v2)",
          "header v2 sem dtb — o mkbootimg recusa e o device precisa da DTB");
    CHECKF(b.file_size >= minimal,
           "tamanho casa com o layout",
           "arquivo tem %llu bytes, mas o layout exige no mínimo %llu (truncado)",
           b.file_size, minimal);

    if (verbose && problems == 0) {
        unsigned long long extra = b.file_size - minimal;
        if (extra > 0)
            printf("  [ok]    %llu bytes além dos blobs (AVB/assinatura/VBMETA)\n", extra);
        printf("\n%sboot.img íntegro%s\n", c.bold, c.reset);
    } else if (verbose) {
        printf("\n%s%d problema(s)%s\n", c.bold, problems, c.reset);
    }

#undef CHECKF
#undef CHECK
    return problems == 0 ? 0 : 1;
}
