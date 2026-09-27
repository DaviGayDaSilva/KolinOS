#!/usr/bin/env bash
# Default KolinOS post-install hook — runs INSIDE the target rootfs.
set -euo pipefail

# Mark the system as KolinOS for scripts and tooling.
echo "kolinos" > /etc/kolinos/target
mkdir -p /etc/kolinos/branding

# Bash completion for all users.
if [ -f /usr/share/bash-completion/bash_completion ]; then
    if ! grep -q 'bash_completion' /etc/bash.bashrc 2>/dev/null; then
        printf '\n# KolinOS: enable bash completion\n[ -f /usr/share/bash-completion/bash_completion ] && . /usr/share/bash-completion/bash_completion\n' >> /etc/bash.bashrc
    fi
fi

# Ensure the KolinOS PATH additions exist.
cat > /etc/profile.d/kolinos-path.sh <<'EOF'
# KolinOS: local binaries
case ":$PATH:" in *":/usr/local/bin:"*) ;; *) PATH="/usr/local/bin:$PATH";; esac
export PATH
EOF
chmod 0644 /etc/profile.d/kolinos-path.sh

exit 0
