# KolinOS dynamic MOTD entry (installed as /etc/profile.d/kolinos.sh).
# Shown only for interactive shells, and only once per login.

export HOSTNAME="@KOLIN_HOSTNAME@"
export KOLINOS="@KOLIN_VERSION@ (@KOLIN_CODENAME@)"

# Colourful prompt that identifies the system.
if [ -n "${PS1:-}" ] || [ "${BASH:-}" ]; then
    PS1='\[\e[1;35m\]\u@\h\[\e[0m\] \[\e[1;36m\]\w\[\e[0m\]\$ '
fi

case "$-" in
    *i*)
        if [ -z "${KOLINOS_BANNER_SHOWN:-}" ] && [ -f /etc/motd ]; then
            cat /etc/motd
            export KOLINOS_BANNER_SHOWN=1
        fi
        ;;
esac
