#!/usr/bin/env bash
#
# Build OpenZFS's kernel modules for QNAP's kernel.
#
# OpenZFS has its own build system, which is pointed at the prepared QNAP
# kernel tree; everything after that - the load order, the vermagic check, the
# packaging - is handled by the generic driver, so this only has to produce the
# modules and list them.
#
# QNAP publishes their own ZFS port in the QuTS Hero GPL drops (zol_h520_*),
# but it is FreeBSD's ZFS and DTrace grafted onto Linux with a renamed SPL and
# it ships no build system, so it is not a buildable base. Upstream OpenZFS
# against QNAP's tree is.
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

: "${FS_MODULE_URL:?fs.mk must set FS_MODULE_URL}"

WORK="$REPO_DIR/build/tools/$FS_NAME-modules"
SRC="$WORK/src"
# One download for both OpenZFS steps: the modules and the userspace build
# from the same tarball.
DL="$REPO_DIR/build/downloads"
TARBALL="$DL/$(basename "$FS_MODULE_URL")"

mkdir -p "$WORK" "$DL" "$(dirname "$MODULE_MANIFEST")"
rm -f "$MODULE_MANIFEST"
: > "$MODULE_MANIFEST"

if [ -s "$TARBALL" ]; then
    log "already downloaded: $(basename "$TARBALL")"
else
    log "downloading $(basename "$FS_MODULE_URL")"
    curl -fL --retry 3 --retry-delay 5 -o "$TARBALL" "$FS_MODULE_URL"
fi

if [ -n "${FS_MODULE_SHA256:-}" ]; then
    echo "$FS_MODULE_SHA256  $TARBALL" | sha256sum -c - >/dev/null ||
        die "$(basename "$TARBALL"): sha256 does not match fs.mk"
fi

if [ ! -f "$SRC/configure" ]; then
    log "unpacking $(basename "$TARBALL")"
    rm -rf "$SRC"
    mkdir -p "$SRC"
    tar -xf "$TARBALL" -C "$SRC" --strip-components=1
fi

cd "$SRC"

# Configured every time: the kernel tree it points at can change, and the
# check is quick compared to the build.
log "configuring against $TREE"
if ! ./configure \
    --with-config=kernel \
    --with-linux="$TREE" \
    --with-linux-obj="$TREE" >"$WORK/configure.log" 2>&1; then
    tail -30 "$WORK/configure.log" >&2
    die "OpenZFS configure failed"
fi

log "building"
if ! make -j"$JOBS" >"$WORK/make.log" 2>&1; then
    grep -iE 'error|Error [0-9]' "$WORK/make.log" | tail -20 >&2
    die "OpenZFS kernel module build failed"
fi

# Everything under module/ is ours. The .ko files configure builds to probe
# the running kernel live in build/ and are not.
for ko in "$SRC"/module/*/*.ko; do
    [ -f "$ko" ] || die "no modules were built in $SRC/module"
    printf '%s\n' "$ko" >> "$MODULE_MANIFEST"
done

log "built $(grep -c . "$MODULE_MANIFEST") modules"
