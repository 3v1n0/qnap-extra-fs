#!/bin/sh
#
# Load, unload or report the kernel modules that came with this package.
#
#   extrafs.sh load      insmod every module, in the order recorded at build time
#   extrafs.sh unload    rmmod them again, in reverse order
#   extrafs.sh status    what is loaded and what is not
#   extrafs.sh list      the modules, in the order they would be loaded
#
# The modules are loaded straight from this directory: nothing is copied into
# the system's module directories, nothing is loaded at boot, and no service
# is started. Running `load` is a decision, not a side effect.
set -eu

self=$(readlink -f "$0" 2>/dev/null || echo "$0")
PREFIX=$(cd "$(dirname "$self")" && pwd)
KVER=$(uname -r)
MODDIR="$PREFIX/modules/$KVER"
ORDER="$MODDIR/order"

die() { echo "ERROR: $*" >&2; exit 1; }

# The order file is checked before it is piped anywhere: a die() on the left
# side of a pipeline only kills that subshell, so the script would report
# success while doing nothing.
require_order() {
    [ -f "$ORDER" ] ||
        die "no module list for kernel $KVER in $PREFIX/modules (this package carries: $(ls "$PREFIX/modules" 2>/dev/null | tr '\n' ' '))"
}

read_order() {
    cat "$ORDER"
}

# busybox does not always have tac, so reverse with sed.
reverse_order() {
    sed '1!G;h;$!d' "$ORDER"
}

is_loaded() {
    [ -d "/sys/module/$1" ]
}

case "${1:-}" in
load)
    [ "$(id -u)" = 0 ] || die "must run as root"
    require_order
    read_order | while read -r ko; do
        [ -n "$ko" ] || continue
        name=${ko%.ko}
        if is_loaded "$name"; then
            echo "already loaded: $name"
            continue
        fi
        [ -f "$MODDIR/$ko" ] || die "missing $MODDIR/$ko"
        insmod "$MODDIR/$ko" || die "insmod $ko failed"
        echo "loaded: $name"
    done
    ;;
unload)
    [ "$(id -u)" = 0 ] || die "must run as root"
    require_order
    reverse_order | while read -r ko; do
        [ -n "$ko" ] || continue
        name=${ko%.ko}
        if ! is_loaded "$name"; then
            echo "not loaded: $name"
            continue
        fi
        rmmod "$name" || die "rmmod $name failed"
        echo "unloaded: $name"
    done
    ;;
status)
    echo "kernel release: $KVER"
    if [ ! -f "$ORDER" ]; then
        echo "no modules for this kernel in $PREFIX/modules"
        echo "this package carries: $(ls "$PREFIX/modules" 2>/dev/null | tr '\n' ' ')"
        exit 1
    fi
    echo "modules:"
    read_order | while read -r ko; do
        [ -n "$ko" ] || continue
        name=${ko%.ko}
        if is_loaded "$name"; then
            state=loaded
        else
            state="not loaded"
        fi
        printf '    %-24s %s\n' "$name" "$state"
    done
    ;;
list)
    require_order
    read_order
    ;;
*)
    echo "usage: $0 {load|unload|status|list}" >&2
    exit 1
    ;;
esac
