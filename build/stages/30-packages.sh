#!/usr/bin/env bash
# Stage 30 — install the KolinOS base package set (Debian packages).
# Reads packages/debian.list; one package per line, '#' comments allowed.
stage_main() {
    local r="$KOLIN_ROOTFS"
    local list="$KOLIN_ROOT_DIR/packages/debian.list"
    [ -f "$list" ] || die "lista de pacotes ausente: $list"

    local pkgs
    pkgs="$(grep -vE '^\s*(#|$)' "$list" | tr '\n' ' ')"
    [ -n "$pkgs" ] || { warn "nenhum pacote em $list"; return 0; }

    log "instalando: $pkgs"
    kolin_run "$r" "export DEBIAN_FRONTEND=noninteractive
        apt-get install -y -qq --no-install-recommends $pkgs"

    log "pacotes base instalados"
}
