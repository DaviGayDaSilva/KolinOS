# KolinOS shell environment (installed as /etc/profile.d/kolinos.sh).
# Colours and identity are rendered from VERSION at build time.

export HOSTNAME="@KOLIN_HOSTNAME@"
export KOLINOS="@KOLIN_VERSION@ (@KOLIN_CODENAME@)"

# Brand colours (quietly skips if the file is missing).
[ -r /etc/kolinos/colors.sh ] && . /etc/kolinos/colors.sh

if [ -n "${BASH:-}" ] || [ -n "${PS1:-}" ]; then
    PS1="\[${KOLIN_C_BOLD}\]\[${KOLIN_C_PRIMARY}\]\u@\h\[${KOLIN_C_RESET}\] \[${KOLIN_C_ACCENT}\]\w\[${KOLIN_C_RESET}\]\$ "
fi

# Show the banner once per interactive login.
case "$-" in
    *i*)
        if [ -z "${KOLINOS_BANNER_SHOWN:-}" ] && [ -f /etc/motd ]; then
            cat /etc/motd
            KOLINOS_BANNER_SHOWN=1
            export KOLINOS_BANNER_SHOWN
        fi
        ;;
esac
