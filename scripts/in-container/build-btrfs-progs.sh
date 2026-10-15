#!/usr/bin/env bash
#
# Build one filesystem's userspace tools inside the tools container.
#
# Everything here is linked statically, so the package carries single files
# with no libraries and nothing to match against the NAS's glibc 2.21.
#
# The build is described entirely by fs/<name>/fs.mk: the tarball, its hash and
# the binaries to keep.
#
# Environment (set by scripts/30-make-tools.sh):
#   FS_NAME   filesystem to build, i.e. fs/<name>/fs.mk
#   JOBS      parallel build jobs
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
TARBALL="$WORK/$(basename "$FS_TOOLS_URL")"

mkdir -p "$WORK" "$DEST"
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

rm -rf "$SRC"
mkdir -p "$SRC"
log "unpacking $(basename "$TARBALL")"
tar -xf "$TARBALL" -C "$SRC" --strip-components=1

cd "$SRC"

# -static: nothing may need the NAS's glibc 2.21.
#
# Backtrace support is off (it is only for error reports and drags in more of
# libc), NLS is off (no libintl), shared libraries are pointless for statically
# linked binaries, zoned (SMR) support is not needed here, and btrfs-convert
# needs e2fsprogs, which this package does not ship.
log "configuring"
CFLAGS="-O2" \
LDFLAGS="-static" \
    ./configure \
        --disable-backtrace \
        --disable-convert \
        --disable-documentation \
        --disable-libudev \
        --disable-python \
        --disable-shared \
        --disable-zoned \
        >/dev/null

log "building"
make -j"$JOBS" >/dev/null

for bin in $FS_TOOLS_BIN; do
    [ -x "$SRC/$bin" ] || die "$bin was not built"
    install -m 755 "$SRC/$bin" "$DEST/$bin"

    # fsck.btrfs is a shell script (btrfs needs no fsck); everything else is a
    # binary and has to be statically linked, which is the whole point of the
    # static build: nothing may need the NAS's glibc 2.21.
    if file -b "$DEST/$bin" | grep -q '^ELF'; then
        strip -s "$DEST/$bin"
        file -b "$DEST/$bin" | grep -q 'statically linked' ||
            die "$bin is not statically linked"
    fi
done

log "tools in $DEST:"
for bin in $FS_TOOLS_BIN; do
    printf '    %-24s %s bytes\n' "$bin" "$(stat -c %s "$DEST/$bin")"
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
