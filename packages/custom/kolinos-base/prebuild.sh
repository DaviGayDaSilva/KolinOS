#!/usr/bin/env bash
# Metapackage: no files of its own. It exists to declare dependencies and to
# leave a marker that the system is a KolinOS installation.
set -euo pipefail

install -d -m 0755 etc/kolinos
printf '%s\n' "${KOLIN_CODENAME:-KolinOS}" > etc/kolinos/target
