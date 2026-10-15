#!/bin/sh
#
# Service program for the QNAP_Btrfs and QNAP_ZFS packages.
#
# It does nothing, on purpose. QTS's installer requires a service program to
# exist: without one it runs "/etc/init.d/ start" and "/etc/init.d/ stop",
# which fail because /etc/init.d/ is a directory, and it builds the package's
# start and stop links from the name. Nothing in this package is started at
# boot: the kernel modules are loaded by load.sh, when you ask for them.
case "${1:-}" in
start | stop | restart | remove)
    ;;
*)
    echo "usage: $0 {start|stop|restart|remove}" >&2
    exit 1
    ;;
esac

exit 0
