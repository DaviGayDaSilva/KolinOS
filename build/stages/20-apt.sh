#!/usr/bin/env bash
# Stage 20 — configure APT sources inside the target and refresh indexes.
# The KolinOS APT repository (Phase 9) plugs in here, disabled by default.
stage_main() {
    local r="$KOLIN_ROOTFS"

    mkdir -p "$r/etc/apt/sources.list.d" "$r/etc/apt/preferences.d" "$r/etc/apt/apt.conf.d"

    # Main Debian suite.
    cat > "$r/etc/apt/sources.list" <<EOF
# KolinOS — Debian base repositories
deb ${KOLIN_DEBIAN_MIRROR} ${KOLIN_DEBIAN_SUITE} main contrib non-free-firmware
deb ${KOLIN_DEBIAN_MIRROR} ${KOLIN_DEBIAN_SUITE}-updates main contrib non-free-firmware
deb ${KOLIN_DEBIAN_SECURITY} ${KOLIN_DEBIAN_SUITE}-security main contrib non-free-firmware
EOF

    # KolinOS's own repository — shipped disabled; enable in Phase 9.
    cat > "$r/etc/apt/sources.list.d/kolinos.sources" <<'EOF'
# KolinOS own APT repository (Phase 9 — disabled until published).
# Enable with: sudo mv /etc/apt/sources.list.d/kolinos.sources.disabled \
#                         /etc/apt/sources.list.d/kolinos.sources
Types: deb
URIs: https://repo.kolinos.org/apt
Suites: corvo
Components: main
Architectures: arm64
Signed-By: /etc/apt/trusted.gpg.d/kolinos.gpg
EOF
    mv "$r/etc/apt/sources.list.d/kolinos.sources" "$r/etc/apt/sources.list.d/kolinos.sources.disabled"

    # APT tuning: keep the image small and friendly to low-storage devices.
    cat > "$r/etc/apt/apt.conf.d/99kolinos" <<'EOF'
// KolinOS APT tuning (low-RAM / low-storage friendly)
APT::Install-Recommends "false";
APT::Install-Suggests  "false";
Acquire::Languages "none";
APT::Clean-Installed "true";
EOF

    log "atualizando índices APT ..."
    kolin_run "$r" 'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq'

    log "sources.list configurado"
}
