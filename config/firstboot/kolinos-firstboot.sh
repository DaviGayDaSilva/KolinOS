# KolinOS — finish first boot on the real machine's first login.
#
# The installer runs /usr/bin/kolinos-firstboot right after deployment. When a
# medium is written by other means (dd, image tools), that step may not have run,
# so this profile hook triggers it on the first interactive login. It is silent
# when it has nothing to do, and never fails the login shell.
#
# Sourced by /etc/profile (see stage 40), so keep it POSIX-friendly.

if [ -x /usr/bin/kolinos-firstboot ] && [ ! -e /etc/kolinos/firstboot.done ]; then
    # Only in an interactive shell, and only as a user allowed to finish setup.
    case "$-" in
        *i*) ;;
        *) return 0 2>/dev/null || true ;;
    esac
    if [ "$(id -u)" -eq 0 ]; then
        /usr/bin/kolinos-firstboot || true
    elif command -v sudo >/dev/null 2>&1; then
        sudo -n /usr/bin/kolinos-firstboot 2>/dev/null || true
    fi
fi
