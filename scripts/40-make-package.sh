#!/usr/bin/env bash
#
# Assemble the installable packages for one filesystem: a QPKG for App Center
# and a plain tarball for the path without it.
#
# Both carry exactly the same payload, so the two cannot drift apart: the
# kernel modules for one release, the static userspace tools, and the small
# scripts that put the tools on PATH and load the modules when asked.
#
# Usage: scripts/40-make-package.sh <fs>
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib.sh"

fs=${1:-}
[ -n "$fs" ] || die "usage: 40-make-package.sh <fs>"
fs_load "$fs"

KERNEL_RELEASE=${KERNEL_RELEASE:-}

mods_root="$(modules_dir)/$FS_NAME"
[ -d "$mods_root" ] || die "no modules built yet (run ./build.sh $FS_NAME modules)"

if [ -z "$KERNEL_RELEASE" ]; then
    releases=$(ls "$mods_root")
    count=$(printf '%s\n' "$releases" | grep -c .)
    [ "$count" = 1 ] ||
        die "several module releases built, pick one with KERNEL_RELEASE=...: $releases"
    KERNEL_RELEASE=$releases
fi

mods="$mods_root/$KERNEL_RELEASE"
[ -d "$mods" ] || die "no modules for release $KERNEL_RELEASE in $mods_root"
[ -f "$mods/order" ] || die "$mods/order is missing (rebuild the modules)"

tools="$(build_dir)/bin/$FS_NAME"
for bin in $FS_TOOLS_BIN; do
    [ -x "$tools/$bin" ] || die "$bin is missing from $tools (run ./build.sh $FS_NAME tools)"
done

out=$(out_dir)
name="qnap-$FS_NAME"

# --------------------------------------------------------------- payload ----

stage="$out/stage/$name"
rm -rf "$stage"
mkdir -p "$stage/bin" "$stage/modules/$KERNEL_RELEASE"

for bin in $FS_TOOLS_BIN; do
    install -m 755 "$tools/$bin" "$stage/bin/$bin"
done
install -m 644 "$mods"/*.ko "$stage/modules/$KERNEL_RELEASE/"
install -m 644 "$mods/order" "$mods/facts.json" "$mods/SHA256SUMS" \
    "$stage/modules/$KERNEL_RELEASE/"

for script in extrafs.sh extrafs-service.sh load.sh unload.sh install.sh uninstall.sh; do
    install -m 755 "$REPO_DIR/shared/$script" "$stage/$script"
done

{
    printf 'FS_NAME=%s\n' "$FS_NAME"
    printf 'FS_TITLE="%s"\n' "$FS_TITLE"
    printf 'PKG_ID=%s\n' "$PKG_ID"
    printf 'PKG_VERSION=%s\n' "$PKG_VERSION"
    printf 'KERNEL_RELEASE=%s\n' "$KERNEL_RELEASE"
} > "$stage/extrafs.conf"

log "payload assembled in $stage"

# --------------------------------------------------------------- tarball ----

tarball="$out/$name-$KERNEL_RELEASE.tar.gz"
rm -f "$tarball"
tar -czf "$tarball" -C "$out/stage" "$name"
log "built $tarball ($(stat -c %s "$tarball") bytes)"

# ------------------------------------------------------------------ QPKG ----
# qbuild only takes qpkg.cfg, package_routines and the contents of shared/
# (which it flattens into the installed package root), so the payload goes
# under shared/ in the source tree.

qpkg_src="$out/qpkg-src/$PKG_ID"
rm -rf "$out/qpkg-src"
mkdir -p "$qpkg_src/shared"

cp -a "$FS_DIR/qpkg/." "$qpkg_src/"
cp -a "$stage/." "$qpkg_src/shared/"
chmod 755 "$qpkg_src/package_routines"

ensure_image "$BUILD_IMAGE" "$REPO_DIR/containers/builder.Containerfile"

log "running qbuild"
sudo podman run --rm \
    --network host \
    --security-opt label=disable \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp -e TMPDIR=/tmp \
    -v "$out":/out \
    -w "/out/qpkg-src/$PKG_ID" \
    "$BUILD_IMAGE" \
    qbuild

# head would SIGPIPE find and, under pipefail, fail the pipeline.
qpkg=$(find "$qpkg_src/build" -name '*.qpkg' -type f 2>/dev/null | sed -n '1p')
[ -n "$qpkg" ] || die "qbuild produced no .qpkg"

final="$out/$(basename "$qpkg")"
cp -f "$qpkg" "$final"
sudo chown "$(id -u):$(id -g)" "$final" 2>/dev/null || true

# QNAP's own .qpkg files are self-extracting shell installers that qpkg_cli and
# App Center run, so ship them executable like QNAP does.
chmod 755 "$final"
log "built $final ($(stat -c %s "$final") bytes)"

log "install with App Center > Install Manually, or:"
log "  scp $final admin@nas:/share/Public/"
log "  ssh admin@nas 'sudo sh /share/Public/$(basename "$final")'"
log "(nothing needs starting afterwards: the package has no service program)"
log "without App Center:"
log "  scp $tarball admin@nas:/share/Public/ && tar xzf $(basename "$tarball") && sudo ./$name/install.sh"
