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

    # Set (or reset) the documented default password with a FIXED salt.
    # chpasswd would pick a random salt, and the salt lands in /etc/shadow —
    # a variable byte that breaks reproducible builds. The hash algorithm must
    # match what `passwd` on the target will later consider valid.
    local hash
    hash="$(openssl passwd -6 -salt kolinos "${KOLIN_DEFAULT_PASSWORD}")"
    [ -n "$hash" ] || die "falha ao gerar o hash da senha (openssl)"
    kolin_run "$r" "usermod -p '$hash' '$u'"

    # useradd runs under qemu-user (or proot) because the target is aarch64, so
    # the host sees the new home as owned by the *host* uid, not the target's.
    # Without this the archive would ship /home/<user> as root:root with mode
    # 0700 — the user could not read their own home. Use the numeric ids from
    # the target's passwd: the names do not resolve on the host.
    local uid gid
    uid="$(kolin_run "$r" "id -u '$u'")"
    gid="$(kolin_run "$r" "id -g '$u'")"
    [ -n "$uid" ] && [ -n "$gid" ] || die "não foi possível resolver uid/gid de '$u'"
    chown -R "$uid:$gid" "$r/home/$u"
    [ -d "$r/var/mail" ] && chown "$uid:$gid" "$r/var/mail/$u" 2>/dev/null || true

    # Passwordless sudo for the default user — convenient in proot, and easy to
    # audit. Remove /etc/sudoers.d/90-kolinos on hardened installs.
    mkdir -p "$r/etc/sudoers.d"
    printf '# KolinOS: allow the default user to sudo without a password.\n# Remove this file for a hardened system.\n%s ALL=(ALL) NOPASSWD:ALL\n' "$u" \
        > "$r/etc/sudoers.d/90-kolinos"
    chmod 0440 "$r/etc/sudoers.d/90-kolinos"

    log "usuário padrão: $u (senha padrão: '${KOLIN_DEFAULT_PASSWORD}' — troque com 'passwd')"
}
