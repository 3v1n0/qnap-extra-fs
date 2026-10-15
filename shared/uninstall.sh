#!/bin/sh
#
# Undo install.sh: remove the symlinks it created in /usr/local/bin.
#
# Only symlinks that point back into this directory are touched, and the
# modules are left loaded: run ./unload.sh first if you want them out.
set -eu

self=$(readlink -f "$0" 2>/dev/null || echo "$0")
PREFIX=$(cd "$(dirname "$self")" && pwd)

[ "$(id -u)" = 0 ] || { echo "run me as root" >&2; exit 1; }

for tool in "$PREFIX"/bin/*; do
    [ -x "$tool" ] || continue
    link="/usr/local/bin/$(basename "$tool")"
    if [ -L "$link" ] && [ "$(readlink "$link")" = "$tool" ]; then
        rm -f "$link"
        echo "removed $link"
    fi
done

echo
echo "Modules are still loaded; $PREFIX/unload.sh unloads them."
