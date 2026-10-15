#!/bin/sh
#
# Load this package's kernel modules (see extrafs.sh for the details).
set -eu
exec "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")/extrafs.sh" load "$@"
