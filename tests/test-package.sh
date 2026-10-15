#!/usr/bin/env bash
#
# Offline checks on a built package: the payload layout, the load order, the
# module metadata and the scripts. Nothing here needs the NAS, and nothing
# gets loaded.
#
# Usage: tests/test-package.sh <fs>
set -uo pipefail

REPO_DIR=${REPO_DIR:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}
# shellcheck source=/dev/null
. "$REPO_DIR/scripts/lib.sh"

fs=${1:-}
[ -n "$fs" ] || die "usage: test-package.sh <fs>"
fs_load "$fs"

pass=0
fail=0
skip=0
ok() { printf 'ok   %s\n' "$*"; pass=$((pass + 1)); }
no() { printf 'FAIL %s\n' "$*"; fail=$((fail + 1)); }
skipped() { printf 'skip %s\n' "$*"; skip=$((skip + 1)); }
check() {
    local desc=$1
    shift
    if "$@" >/dev/null 2>&1; then ok "$desc"; else no "$desc"; fi
}

out=$(out_dir)
stage="$out/stage/qnap-$FS_NAME"

printf '== %s: payload ==\n' "$FS_TITLE"
check "payload directory exists" test -d "$stage"
[ -d "$stage" ] || { printf '\n%s: %d passed, %d failed\n' "$FS_NAME" "$pass" "$fail"; exit 1; }

krel=$(sed -n 's/^KERNEL_RELEASE=//p' "$stage/extrafs.conf")
check "extrafs.conf records the kernel release" test -n "$krel"
check "extrafs.conf names the filesystem" grep -qx "FS_NAME=$FS_NAME" "$stage/extrafs.conf"
check "modules for $krel are in the payload" test -d "$stage/modules/$krel"
check "a load order is recorded" test -s "$stage/modules/$krel/order"
check "the module list is not empty" test "$(grep -c . "$stage/modules/$krel/order")" -gt 0

printf '== %s: userspace ==\n' "$FS_TITLE"
for bin in $FS_TOOLS_BIN; do
    check "$bin is in the payload" test -x "$stage/bin/$bin"
    # fsck.btrfs is a shell script; everything else must be statically linked.
    if file -b "$stage/bin/$bin" 2>/dev/null | grep -q '^ELF'; then
        check "$bin is statically linked" \
            bash -c "file '$stage/bin/$bin' | grep -q 'statically linked'"
    else
        ok "$bin is a script, nothing to link"
    fi
done

printf '== %s: modules ==\n' "$FS_TITLE"
moddir="$stage/modules/$krel"
for ko in "$moddir"/*.ko; do
    [ -f "$ko" ] || continue
    name=$(basename "$ko" .ko)
    got=$(modinfo -F vermagic "$ko" 2>/dev/null | sed 's/[[:space:]]*$//')
    if [ "$got" = "$krel SMP mod_unload" ]; then
        ok "$name vermagic is '$krel SMP mod_unload'"
    else
        no "$name vermagic is '$got', expected '$krel SMP mod_unload'"
    fi
done

# Every module in the payload is listed once, every listed module exists, and
# nothing is loaded before something it depends on.
listed=$(grep -c . "$moddir/order")
present=$(ls "$moddir"/*.ko 2>/dev/null | wc -l)
check "every module appears in the order file" test "$listed" = "$present"
while read -r ko; do
    [ -n "$ko" ] || continue
    check "$ko exists" test -f "$moddir/$ko"
done < "$moddir/order"

missing_dep=0
seen=" "
while read -r ko; do
    [ -n "$ko" ] || continue
    name=${ko%.ko}
    for dep in $(modinfo -F depends "$moddir/$ko" 2>/dev/null | tr ',' ' '); do
        [ -n "$dep" ] || continue
        case "$seen" in
            *" $dep "*) ;;
            *) printf 'FAIL %s is loaded before its dependency %s\n' "$name" "$dep"
               missing_dep=$((missing_dep + 1)) ;;
        esac
    done
    seen="$seen$name "
done < "$moddir/order"
if [ "$missing_dep" = 0 ]; then
    ok "the load order satisfies every module dependency"
else
    fail=$((fail + missing_dep))
fi

check "facts.json names the filesystem" grep -q "\"filesystem\": \"$FS_NAME\"" "$moddir/facts.json"
check "facts.json names the release" grep -q "\"kernel_release\": \"$krel\"" "$moddir/facts.json"
check "the module checksums verify" \
    bash -c "cd '$moddir' && sha256sum -c SHA256SUMS >/dev/null 2>&1"

printf '== %s: scripts ==\n' "$FS_TITLE"
for script in extrafs.sh extrafs-service.sh load.sh unload.sh install.sh uninstall.sh; do
    check "$script is in the payload" test -f "$stage/$script"
    check "$script parses" sh -n "$stage/$script"
    check "$script is executable" test -x "$stage/$script"
done

# extrafs.sh takes the release from uname, so give it a payload for this
# host's kernel to exercise the list/status paths without needing the NAS.
fake=$(mktemp -d)
mkdir -p "$fake/modules/$(uname -r)"
cp "$stage/extrafs.sh" "$fake/"
cp "$moddir/order" "$fake/modules/$(uname -r)/order"

if [ "$("$fake/extrafs.sh" list 2>/dev/null)" = "$(cat "$moddir/order")" ]; then
    ok "extrafs.sh list prints the load order"
else
    no "extrafs.sh list prints the load order"
fi

missing_name=0
status_out=$("$fake/extrafs.sh" status 2>&1)
for name in $(sed 's/\.ko$//' "$moddir/order"); do
    case "$status_out" in
        *"$name"*) ;;
        *) printf 'FAIL status does not mention %s\n' "$name"; missing_name=$((missing_name + 1)) ;;
    esac
done
if [ "$missing_name" = 0 ]; then
    ok "extrafs.sh status lists every module"
else
    fail=$((fail + missing_name))
fi
rm -rf "$fake"

# status has to refuse a kernel this package has no modules for, rather than
# pretend everything is fine.
if [ "$(uname -r)" != "$krel" ]; then
    if "$stage/extrafs.sh" status >/dev/null 2>&1; then
        no "status refuses a kernel without modules"
    else
        ok "status refuses a kernel without modules"
    fi
else
    skipped "status refusal (running kernel is the target kernel)"
fi

printf '== %s: install/uninstall ==\n' "$FS_TITLE"
# The first tool every package carries; used to prove install/uninstall work.
probe_tool=${FS_TOOLS_BIN%% *}
if sudo podman image exists alpine:3.20 2>/dev/null || sudo podman pull -q alpine:3.20 >/dev/null 2>&1; then
    if sudo podman run --rm -e TOOL="$probe_tool" -v "$stage":/pkg:ro alpine:3.20 sh -c '
        set -e
        /pkg/install.sh >/dev/null
        [ -L "/usr/local/bin/$TOOL" ] || exit 1
        [ "$(readlink "/usr/local/bin/$TOOL")" = "/pkg/bin/$TOOL" ] || exit 1
        # loading must refuse here: this container is not that kernel
        if /pkg/load.sh >/dev/null 2>&1; then exit 1; fi
        /pkg/uninstall.sh >/dev/null
        [ ! -e "/usr/local/bin/$TOOL" ] || exit 1
        exit 0
    ' >/dev/null 2>&1; then
        ok "install.sh links the tools, load.sh refuses, uninstall.sh cleans up"
    else
        no "install.sh links the tools, load.sh refuses, uninstall.sh cleans up"
    fi
else
    skipped "install/uninstall container check (no alpine image)"
fi

# The QPKG install routines are sourced by QTS's installer, which is where the
# install path comes from (SYS_QPKG_DIR). They must work without Install_Path in
# qpkg.conf, must never abort the installation over it, and must fall back to
# the payload in the working directory when nothing else is known.
if sudo podman image exists alpine:3.20 2>/dev/null; then
    if sudo podman run --rm -e TOOL="$probe_tool" -e SYS_QPKG_DIR=/pkg \
        -v "$stage":/pkg:ro -v "$FS_DIR/qpkg":/routines:ro alpine:3.20 sh -c '
        set -e
        cd /tmp
        . /routines/package_routines
        pkg_pre_install
        pkg_install
        pkg_post_install
        [ -L "/usr/local/bin/$TOOL" ] || exit 1
        [ "$(readlink "/usr/local/bin/$TOOL")" = "/pkg/bin/$TOOL" ] || exit 1
        pkg_pre_remove
        [ ! -e "/usr/local/bin/$TOOL" ] || exit 1
        exit 0
    ' >/dev/null 2>&1; then
        ok "package_routines find the payload through the installer's path"
    else
        no "package_routines find the payload through the installer's path"
    fi

    if sudo podman run --rm -e TOOL="$probe_tool" \
        -v "$stage":/pkg:ro -v "$FS_DIR/qpkg":/routines:ro alpine:3.20 sh -c '
        set -e
        cd /pkg
        . /routines/package_routines
        pkg_pre_install
        pkg_install
        pkg_post_install
        [ -L "/usr/local/bin/$TOOL" ] || exit 1
        [ "$(readlink "/usr/local/bin/$TOOL")" = "/pkg/bin/$TOOL" ] || exit 1
        pkg_pre_remove
        [ ! -e "/usr/local/bin/$TOOL" ] || exit 1
        exit 0
    ' >/dev/null 2>&1; then
        ok "package_routines fall back to the payload in the working directory"
    else
        no "package_routines fall back to the payload in the working directory"
    fi
else
    skipped "package_routines check (no alpine image)"
fi

printf '== %s: QPKG ==\n' "$FS_TITLE"
qpkg=$(ls "$out/${PKG_ID}_"*.qpkg 2>/dev/null | sed -n '1p')
if [ -n "$qpkg" ]; then
    ok "QPKG built: $(basename "$qpkg")"
    check "QPKG is executable" test -x "$qpkg"
    if tar -tzf "$qpkg" >/dev/null 2>&1; then
        check "QPKG carries qpkg.cfg" bash -c "tar -tzf '$qpkg' | grep -q 'qpkg.cfg'"
        check "QPKG carries package_routines" bash -c "tar -tzf '$qpkg' | grep -q 'package_routines'"
        check "QPKG carries the modules" bash -c "tar -tzf '$qpkg' | grep -q 'modules/$krel/order'"
        check "QPKG carries the tools" bash -c "tar -tzf '$qpkg' | grep -q 'bin/mkfs.btrfs'"
    else
        skipped "QPKG contents (self-extracting archive, not a plain tar)"
    fi
else
    no "QPKG built"
fi

printf '\n%s: %d passed, %d failed, %d skipped\n' "$FS_NAME" "$pass" "$fail" "$skip"
[ "$fail" = 0 ]
