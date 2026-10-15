#!/usr/bin/env bash
#
# Build the filesystem modules and userspace tools for a QNAP NAS.
#
#   ./build.sh                      fetch the kernel source, then build every
#                                   filesystem: modules, tools, packages
#   ./build.sh fetch                fetch/unpack QNAP's GPL kernel source
#   ./build.sh btrfs                modules + tools + package for btrfs
#   ./build.sh zfs                  modules + tools + package for zfs
#   ./build.sh btrfs modules        just one step of one filesystem
#   ./build.sh btrfs tools
#   ./build.sh btrfs package
#   ./build.sh test                 run the test suite
#   ./build.sh clean                remove build artifacts
#
# Environment:
#   MODEL            QNAP model whose kernel config to use (e.g. TS-X53II)
#   KERNEL_RELEASE   assert this release instead of the tree's own
#   QTS_GPL          QNAP GPL release to fetch (default 5.2.3.20250218)
#   GPL_CACHE_DIR    where the GPL archives live (point it at another
#                    checkout to avoid downloading them again)
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/scripts/lib.sh"

cmd=${1:-all}
step=${2:-}

fs_steps() {
    local fs=$1 step=$2
    case "$step" in
        modules) "$REPO_DIR/scripts/20-make-modules.sh" "$fs" ;;
        tools) "$REPO_DIR/scripts/30-make-tools.sh" "$fs" ;;
        package) "$REPO_DIR/scripts/40-make-package.sh" "$fs" ;;
        "") "$REPO_DIR/scripts/20-make-modules.sh" "$fs"
            "$REPO_DIR/scripts/30-make-tools.sh" "$fs"
            "$REPO_DIR/scripts/40-make-package.sh" "$fs" ;;
        *) die "unknown step: $step (modules|tools|package)" ;;
    esac
}

case "$cmd" in
    all)
        "$REPO_DIR/scripts/00-fetch-gpl.sh"
        for fs in $(fs_list); do
            fs_steps "$fs" "$step"
        done
        ;;
    fetch) "$REPO_DIR/scripts/00-fetch-gpl.sh" ;;
    test) "$REPO_DIR/tests/test-all.sh" ;;
    clean) rm -rf "$REPO_DIR/build" "$REPO_DIR/out"; log "removed build/ and out/" ;;
    *)
        fs_load "$cmd"
        fs_steps "$cmd" "$step"
        ;;
esac
