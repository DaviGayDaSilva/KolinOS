#!/usr/bin/env bash
# Stage 32 — cross-compile the KolinOS native tools (C) for the target.
#
# This stage exists because the project shipped only shell for its first eight
# phases: the build host had no cross toolchain, so producing native ARM64 code
# was not possible. Installing gcc-aarch64-linux-gnu removes that obstacle, and
# the C sources under src/ are compiled here into statically linked ARM64
# binaries.
#
# Runs *before* stage 35 (packages), which packages the resulting binaries into
# KolinOS's own .deb files — so the native tools reach the rootfs through APT
# like everything else, rather than being copied in by hand.
#
# Requirements and limits:
#  - Needs a cross compiler on the *build host*. On Termux there is no
#    gcc-aarch64-linux-gnu; this stage detects that and skips with a clear
#    message instead of failing the build. The other stages keep working.
#  - --static keeps the binaries independent of the target's libc and dynamic
#    loader, so they also run inside proot and in a half-broken rootfs.
stage_main() {
    local r="$KOLIN_ROOTFS"

    if [ "${KOLIN_NATIVE:-1}" != 1 ]; then
        log "pulando ferramentas nativas (--no-native)"
        return 0
    fi

    local cross="aarch64-linux-gnu-"
    if ! command -v "${cross}gcc" >/dev/null 2>&1; then
        warn "cross-compilador '${cross}gcc' ausente; pulando ferramentas nativas (C)"
        warn "instale no host: apt-get install gcc-aarch64-linux-gnu"
        warn "no Termux esse pacote não existe — as ferramentas nativas são opcionais"
        return 0
    fi

    # build-deb.sh and the rootfs stages read these from VERSION; keep the
    # compile in the same reproducibility regime (FASE 4).
    export SOURCE_DATE_EPOCH="$KOLIN_BUILD_EPOCH"

    log "compilando ferramentas nativas para ${DEB_ARCH} ..."
    make -C "$KOLIN_ROOT_DIR" clean >/dev/null 2>&1 || true
    CROSS="$cross" BINDIR=build/native \
        make -C "$KOLIN_ROOT_DIR" all \
        || die "compilação nativa (C) falhou"

    # Verify the architecture actually produced. A silently native binary would
    # otherwise be packaged as arm64 and fail only on the target.
    local out="$KOLIN_ROOT_DIR/build/native"
    local f
    for f in "$out"/*; do
        [ -f "$f" ] || continue
        local machine
        if command -v "${cross}readelf" >/dev/null 2>&1; then
            machine="$("${cross}readelf" -h "$f" | awk '/Machine:/{print $2}')"
        else
            machine="$(file -b "$f" 2>/dev/null | grep -o 'AArch64\|x86-64\|aarch64' | head -1)"
        fi
        [ -n "$machine" ] || die "não foi possível identificar a arquitetura de $(basename "$f")"
        case "$DEB_ARCH" in
            arm64|aarch64) want="AArch64" ;;
            amd64|x86_64)  want="x86-64" ;;
            *)             want="" ;;
        esac
        if [ -n "$want" ] && [ "$machine" != "$want" ]; then
            die "$(basename "$f") está em $machine, esperado $want"
        fi
        log "  $(basename "$f"): $machine ($(stat -c%s "$f") bytes)"
    done

    # Stage 35 packages them; this is only a sanity check that the build
    # produced something to package.
    local n
    n="$(find "$out" -maxdepth 1 -type f | wc -l)"
    [ "$n" -gt 0 ] || die "nenhum binário nativo gerado em $out"
    log "$n ferramentas nativas prontas para empacotamento"
}
