#!/usr/bin/env bash
#
# Build modules that live in the QNAP kernel tree itself, one kbuild target at
# a time.
#
# The modules are built out of tree (M=<dir> <name>.ko) because the kernel
# configuration has to be pinned per module, and because that is the only way
# a partial build can resolve a reference from one module to another:
# KBUILD_EXTRA_SYMBOLS carries the symbols of the modules built before it.
# fs.mk therefore lists the targets in dependency order, and the modules built
# out of tree keep their symbols in their own directory, leaving the tree's
# own Module.symvers untouched.
#
# Environment (set by scripts/in-container/build-modules.sh):
#   TREE             the prepared QNAP kernel tree
#   MODULE_MANIFEST  where to write the built modules, one path per line
#   TARGET_ARCH      kbuild ARCH= value
#   JOBS             parallel build jobs
set -euo pipefail

REPO_DIR=${REPO_DIR:-/work}
TREE=${TREE:?TREE is required}
MODULE_MANIFEST=${MODULE_MANIFEST:?MODULE_MANIFEST is required}
TARGET_ARCH=${TARGET_ARCH:-$(uname -m)}
JOBS=${JOBS:-$(nproc)}
FS_NAME=${FS_NAME:?FS_NAME is required}

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# shellcheck source=/dev/null
. "$REPO_DIR/fs/$FS_NAME/fs.mk"

: "${FS_MODULE_TARGETS:?fs.mk must set FS_MODULE_TARGETS for the kbuild builder}"

symvers_dir="$REPO_DIR/build/symvers/$FS_NAME"
mkdir -p "$symvers_dir"
rm -f "$symvers_dir"/*.symvers
: > "$MODULE_MANIFEST"

local_extra=()

while read -r target opts; do
    [ -n "$target" ] || continue
    dir=$(dirname "$target")
    base=$(basename "$target")
    name=${base%.ko}

    log "building $target"
    # shellcheck disable=SC2086 # opts is a list of VAR=value pairs
    make -C "$TREE" ARCH="$TARGET_ARCH" M="$TREE/$dir" "$base" \
        $opts KBUILD_EXTRA_SYMBOLS="${local_extra[*]:-}" -j"$JOBS" >/dev/null
    [ -f "$TREE/$target" ] || die "expected $TREE/$target after building it"

    printf '%s\n' "$TREE/$target" >> "$MODULE_MANIFEST"

    # Keep what this module exports for the modules built after it.
    if [ -f "$TREE/$dir/Module.symvers" ]; then
        cp -f "$TREE/$dir/Module.symvers" "$symvers_dir/$name.symvers"
        local_extra+=("$symvers_dir/$name.symvers")
    fi
done <<EOF
$FS_MODULE_TARGETS
${FS_EXTRA_MODULES:-}
EOF
