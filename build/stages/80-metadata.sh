#!/usr/bin/env bash
# Stage 80 — write build metadata (checksums, manifest, license notice).
stage_main() {
    local out="$KOLIN_OUTPUT_DIR"
    mkdir -p "$out"

    local tarball="$out/kolinos-${KOLIN_VERSION}-${KOLIN_CODENAME_LOWER}-${KOLIN_ARCH}.tar.xz"
    local meta="$out/METADATA.txt"

    {
        echo "KolinOS build metadata"
        echo "======================"
        echo "name          : ${KOLIN_NAME}"
        echo "version       : ${KOLIN_VERSION}"
        echo "codename      : ${KOLIN_CODENAME}"
        echo "debian suite  : ${KOLIN_DEBIAN_SUITE}"
        echo "architecture  : ${KOLIN_ARCH} (${DEB_ARCH})"
        echo "built on      : $(uname -srm)"
        echo "build epoch   : ${KOLIN_BUILD_EPOCH}"
        echo "build date    : $(kolin_iso_utc "$KOLIN_BUILD_EPOCH")"
        if [ -n "${KOLIN_SNAPSHOT:-}" ]; then
            echo "snapshot      : ${KOLIN_SNAPSHOT} (reprodutível)"
        else
            echo "snapshot      : nenhum (mirror ao vivo — build não reprodutível)"
        fi
        echo "git commit    : $(git -C "$KOLIN_ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo n/a)"
        echo
        echo "Artifacts:"
        for f in "$out"/*; do
            [ -f "$f" ] || continue
            printf '  %-60s %10s\n' "$(basename "$f")" "$(human_size "$f")"
        done
        echo
        echo "License notice:"
        echo "  This rootfs contains Debian packages, which are distributed under"
        echo "  their own licenses. See /usr/share/doc/*/copyright inside the image."
        echo "  The KolinOS build scripts are licensed under the terms in LICENSE."
    } > "$meta"

    log "checksums (sha256):"
    ( cd "$out" && rm -f SHA256SUMS && sha256sum ./*.tar.* ./*.iso 2>/dev/null | tee SHA256SUMS ) || true

    log "metadados escritos em $meta"
}
