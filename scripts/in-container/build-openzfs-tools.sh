#!/usr/bin/env bash
#
# Build OpenZFS's userspace tools, statically.
#
# The NAS runs glibc 2.21, so everything is linked statically: no libc version
# to match and no libraries to ship. libtool needs -all-static for that, not
# just -static.
#
# Environment (set by scripts/30-make-tools.sh):
#   FS_NAME  filesystem to build, i.e. fs/<name>/fs.mk
#   JOBS     parallel build jobs
set -euo pipefail

REPO_DIR=${REPO_DIR:-/work}
JOBS=${JOBS:-$(nproc)}
FS_NAME=${FS_NAME:?FS_NAME is required}

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# shellcheck source=/dev/null
. "$REPO_DIR/fs/$FS_NAME/fs.mk"

WORK="$REPO_DIR/build/tools/$FS_NAME"
SRC="$WORK/src"
DEST="$REPO_DIR/build/bin/$FS_NAME"
# One download for both OpenZFS steps: the modules and the userspace build
# from the same tarball.
DL="$REPO_DIR/build/downloads"
TARBALL="$DL/$(basename "$FS_TOOLS_URL")"

mkdir -p "$WORK" "$DEST" "$DL"
rm -f "$DEST"/*

if [ -s "$TARBALL" ]; then
    log "already downloaded: $(basename "$TARBALL")"
else
    log "downloading $(basename "$FS_TOOLS_URL")"
    curl -fL --retry 3 --retry-delay 5 -o "$TARBALL" "$FS_TOOLS_URL"
fi

if [ -n "$FS_TOOLS_SHA256" ]; then
    echo "$FS_TOOLS_SHA256  $TARBALL" | sha256sum -c - >/dev/null ||
        die "$(basename "$TARBALL"): sha256 does not match fs.mk"
fi

if [ ! -f "$SRC/configure" ]; then
    log "unpacking $(basename "$TARBALL")"
    rm -rf "$SRC"
    mkdir -p "$SRC"
    tar -xf "$TARBALL" -C "$SRC" --strip-components=1
fi

cd "$SRC"

# Shared libraries are pointless when the binaries are static, NLS would pull
# in libintl, and the systemd/SysV units are for a system that runs them.
log "configuring"
if ! ./configure \
    --with-config=user \
    --disable-shared \
    --enable-static \
    --disable-nls \
    --disable-systemd \
    --disable-sysvinit >"$WORK/configure.log" 2>&1; then
    tail -30 "$WORK/configure.log" >&2
    die "OpenZFS configure failed"
fi

# -all-static is libtool's flag for a fully static program; plain -static is
# ignored on the libtool link line, which is how the first attempt ended up
# with dynamic binaries. -ldl has to go through LIBS rather than LDFLAGS:
# glibc 2.31 keeps dlopen and friends in libdl.a, and automake puts LIBS after
# the objects, which is the only order a static link resolves.
log "building (static)"
if ! make -j"$JOBS" LDFLAGS="-all-static" LIBS="-ldl" >"$WORK/make.log" 2>&1; then
    grep -iE 'error|Error [0-9]|undefined reference' "$WORK/make.log" | tail -20 >&2
    die "OpenZFS userspace build failed"
fi

for bin in $FS_TOOLS_BIN; do
    dir=$(printf '%s' "$bin" | tr '.' '_')
    src="$SRC/cmd/$dir/$bin"
    [ -x "$src" ] || die "$bin was not built (looked for $src)"
    install -m 755 "$src" "$DEST/$bin"

    # fsck.zfs is a shell script; the rest are binaries and have to be static.
    if file -b "$DEST/$bin" | grep -q '^ELF'; then
        strip -s "$DEST/$bin"
        file -b "$DEST/$bin" | grep -q 'statically linked' ||
            die "$bin is not statically linked"
    fi
done

log "tools in $DEST:"
for bin in $FS_TOOLS_BIN; do
    printf '    %-16s %s bytes\n' "$bin" "$(stat -c %s "$DEST/$bin")"
done

{
    printf '{\n'
    printf '  "filesystem": "%s",\n' "$FS_NAME"
    printf '  "version": "%s",\n' "$FS_TOOLS_VERSION"
    printf '  "url": "%s"\n' "$FS_TOOLS_URL"
    printf '}\n'
} > "$DEST/facts.json"
( cd "$DEST" && sha256sum ./* | grep -v 'SHA256SUMS$' > SHA256SUMS )

log "done"
