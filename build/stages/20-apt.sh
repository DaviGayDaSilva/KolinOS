#!/usr/bin/env bash
# Stage 20 — configure APT sources inside the target and refresh indexes.
# Sources come from config/apt/*.in (templated from VERSION); the KolinOS APT
# repository (Phase 9) is shipped disabled by default.
stage_main() {
    local r="$KOLIN_ROOTFS"

    mkdir -p "$r/etc/apt/sources.list.d" "$r/etc/apt/preferences.d" \
             "$r/etc/apt/apt.conf.d" "$r/etc/apt/trusted.gpg.d"

    # Reproducibility: point APT at the fixed snapshot when one is selected.
    export KOLIN_APT_MAIN_MIRROR="$(kolin_effective_mirror "$KOLIN_DEBIAN_MIRROR")"
    export KOLIN_APT_SEC_MIRROR="$(kolin_effective_mirror "$KOLIN_DEBIAN_SECURITY")"

    # snapshot.debian.org serves Release files as they were, so their Valid-Until
    # date is in the past. Scope the check off for those repositories only.
    # Empty for a live mirror, so Debian's normal expiry check stays active.
    if [ -n "${KOLIN_SNAPSHOT:-}" ]; then
        export KOLIN_APT_SNAPSHOT_OPT="[check-valid-until=no] "
    else
        export KOLIN_APT_SNAPSHOT_OPT=""
    fi

    render_template "$KOLIN_ROOT_DIR/config/apt/sources.list.in" "$r/etc/apt/sources.list"
    render_template "$KOLIN_ROOT_DIR/config/apt/kolinos.sources.in" \
        "$r/etc/apt/sources.list.d/kolinos.sources.disabled"

    # APT tuning: keep the image small and friendly to low-storage devices.
    install -m 0644 "$KOLIN_ROOT_DIR/config/apt/kolinos-apt.conf" \
        "$r/etc/apt/apt.conf.d/99kolinos"

    log "atualizando índices APT ..."
    kolin_run "$r" 'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq'

    log "sources.list configurado"
}
