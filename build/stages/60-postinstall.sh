#!/usr/bin/env bash
# Stage 60 — run custom post-installation hooks inside the rootfs.
#
# Hooks live in config/postinstall/*.sh (run in lexical order). Each is copied
# into the rootfs and executed there, so it can rely on the target environment.
stage_main() {
    local r="$KOLIN_ROOTFS"
    local dir="$KOLIN_ROOT_DIR/config/postinstall"

    # NOTE: /usr/local/bin tools are owned by the kolinos-tools package now
    # (stage 35), not copied here — dpkg must be the owner so that
    # 'apt install --reinstall kolinos-tools' and 'dpkg -V' behave correctly.

    shopt -s nullglob
    local hooks=("$dir"/*.sh)
    shopt -u nullglob
    if [ "${#hooks[@]}" -eq 0 ]; then
        warn "nenhum hook de pós-instalação em $dir"
        return 0
    fi

    local h name
    for h in "${hooks[@]}"; do
        name="$(basename "$h")"
        log "hook: $name"
        install -D -m 0755 "$h" "$r/tmp/kolinos-hook-$name"
        kolin_run "$r" "/tmp/kolinos-hook-$name"
        rm -f "$r/tmp/kolinos-hook-$name"
    done

    log "pós-instalação concluída"
}
