#!/usr/bin/env bash
# Stage 35 — install KolinOS's own packages (FASE 5).
#
# The .deb files are built by scripts/host/build-deb.sh, indexed into a local
# APT repository and then installed with apt-get — so dependencies between our
# packages and on Debian packages are resolved for real, exactly as they will be
# on a user's machine. This is the milestone of FASE 5: KolinOS packages coming
# in through APT instead of being copied into the rootfs by hand.
#
# A file:// repository is used, so the build needs no network here.
stage_main() {
    local r="$KOLIN_ROOTFS"
    local reb="$(printf '%s' "$KOLIN_CODENAME" | tr '[:upper:]' '[:lower:]')"

    # Build the .deb files for the *target* architecture. Deterministic (FASE 4).
    log "empacotando pacotes próprios ..."
    SOURCE_DATE_EPOCH="$KOLIN_BUILD_EPOCH" KOLIN_BUILD_EPOCH="$KOLIN_BUILD_EPOCH" \
        KOLIN_DEB_ARCH="$DEB_ARCH" \
        bash "$KOLIN_ROOT_DIR/scripts/host/build-deb.sh"

    # Assemble the local repository from those .debs.
    local pub="$KOLIN_ROOT_DIR/repo/public"
    KOLIN_REPO_PUB="$pub" SOURCE_DATE_EPOCH="$KOLIN_BUILD_EPOCH" \
        KOLIN_DEB_ARCH="$DEB_ARCH" \
        bash "$KOLIN_ROOT_DIR/repo/scripts/build-repo.sh" --unsigned >/dev/null

    # Hand the repository to the target and point APT at it. A file:// URL inside
    # a chroot refers to the rootfs itself, so the tree is copied to a temporary
    # in-rootfs path and removed again after installation.
    log "instalando pacotes KolinOS via APT ..."
    local tmp="/var/tmp/kolinos-repo"
    rm -rf "$r$tmp"
    install -d -m 0755 "$r$tmp"
    cp -a "$pub/." "$r$tmp/"

    # trusted=yes: the local repository is unsigned. It is created and consumed
    # entirely inside this build and never leaves the machine. The published
    # repository (FASE 9) is signed and uses Signed-By in kolinos.sources.
    cat > "$r/etc/apt/sources.list.d/90-kolinos-build.list" <<EOF
deb [trusted=yes] file://$tmp $reb main
EOF

    # kolinos-desktop (FASE 7) is opt-in: when enabled, it is installed together
    # with the base so the desktop's Debian dependencies (openbox, picom, …) are
    # resolved by APT against the live Debian mirror, exactly like on a user's
    # machine. Without --with-desktop the system keeps only the lean base set.
    local install_set="kolinos-base"
    if [ "${KOLIN_DESKTOP:-0}" = 1 ]; then
        install_set="kolinos-base kolinos-desktop"
        log "incluindo o desktop Corvo Glass (--with-desktop)"
    fi

    kolin_run "$r" "export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq --no-install-recommends $install_set"

    # The metapackage depends on kolinos-tools|branding, but the specific
    # provider must be pinned so APT cannot satisfy it with a same-named
    # package from Debian's archive (Debian has no such packages today, but the
    # intent should be explicit). Record what got installed for verification.
    mkdir -p "$KOLIN_OUTPUT_DIR"
    kolin_run "$r" "dpkg-query -W -f='\${Package} \${Version} \${Architecture}\n' \
        kolinos-base kolinos-tools kolinos-branding kolinos-theme kolinos-desktop \
        2>/dev/null | sort" \
        > "$KOLIN_OUTPUT_DIR/kolinos-packages.txt"

    log "pacotes KolinOS instalados:"
    sed 's/^/  /' "$KOLIN_OUTPUT_DIR/kolinos-packages.txt"

    # Drop the temporary repo and its source list: it is a build-time artifact,
    # not part of the shipped system. The .deb files stay in the local pool so
    # 'apt-get install --reinstall kolinos-base' still works, and the disabled
    # kolinos.sources file (FASE 9) documents the future remote repo.
    rm -rf "$r$tmp"
    rm -f "$r/etc/apt/sources.list.d/90-kolinos-build.list"

    log "pacotes próprios integrados"
}
