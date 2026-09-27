#!/usr/bin/env bash
# Stage 50 — create the default user and groups.
stage_main() {
    local r="$KOLIN_ROOTFS"
    local u="$KOLIN_DEFAULT_USER"

    if kolin_run "$r" "id -u '$u' >/dev/null 2>&1"; then
        log "usuário '$u' já existe"
    else
        log "criando usuário '$u'"
        # Only add supplementary groups that actually exist in this rootfs.
        local groups="" g
        for g in sudo audio video netdev plugdev; do
            if kolin_run "$r" "getent group '$g' >/dev/null"; then groups="$groups,$g"; fi
        done
        groups="${groups#,}"
        if [ -n "$groups" ]; then
            kolin_run "$r" "useradd -m -s /bin/bash -G '$groups' '$u'"
        else
            kolin_run "$r" "useradd -m -s /bin/bash '$u'"
        fi
    fi

    # Set (or reset) the documented default password.
    kolin_run "$r" "echo '$u:${KOLIN_DEFAULT_PASSWORD}' | chpasswd"

    # Passwordless sudo for the default user — convenient in proot, and easy to
    # audit. Remove /etc/sudoers.d/90-kolinos on hardened installs.
    mkdir -p "$r/etc/sudoers.d"
    printf '# KolinOS: allow the default user to sudo without a password.\n# Remove this file for a hardened system.\n%s ALL=(ALL) NOPASSWD:ALL\n' "$u" \
        > "$r/etc/sudoers.d/90-kolinos"
    chmod 0440 "$r/etc/sudoers.d/90-kolinos"

    log "usuário padrão: $u (senha padrão: '${KOLIN_DEFAULT_PASSWORD}' — troque com 'passwd')"
}
