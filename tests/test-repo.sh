#!/usr/bin/env bash
#
# Repository-level checks: the build scripts parse, and every filesystem's
# fs.mk and QPKG configuration agree with each other.
set -uo pipefail

REPO_DIR=${REPO_DIR:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}
# shellcheck source=/dev/null
. "$REPO_DIR/scripts/lib.sh"

pass=0
fail=0
ok() { printf 'ok   %s\n' "$*"; pass=$((pass + 1)); }
no() { printf 'FAIL %s\n' "$*"; fail=$((fail + 1)); }
check() {
    local desc=$1
    shift
    if "$@" >/dev/null 2>&1; then ok "$desc"; else no "$desc"; fi
}

printf '== build scripts ==\n'
for script in "$REPO_DIR/build.sh" "$REPO_DIR"/scripts/*.sh "$REPO_DIR"/scripts/in-container/*.sh; do
    check "$(basename "$script") parses" bash -n "$script"
done
for script in "$REPO_DIR"/shared/*.sh; do
    check "shared/$(basename "$script") parses" sh -n "$script"
done
check "scripts are executable" test -x "$REPO_DIR/build.sh"
for script in "$REPO_DIR"/scripts/*.sh "$REPO_DIR"/shared/*.sh; do
    check "$(basename "$script") is executable" test -x "$script"
done

printf '== filesystems ==\n'
for fs in $(fs_list); do
    fs_load "$fs"
    check "$fs: fs.mk sets a package id" test -n "$PKG_ID"
    check "$fs: fs.mk sets a version" test -n "$PKG_VERSION"
    check "$fs: fs.mk lists tools" test -n "$FS_TOOLS_BIN"

    # Modules either come from kbuild targets in the kernel tree or from an
    # external build system; fs.mk has to say which.
    if [ -n "${FS_MODULE_TARGETS:-}" ] || [ -n "${FS_MODULE_URL:-}" ]; then
        ok "$fs: fs.mk says how to build its modules"
    else
        no "$fs: fs.mk says how to build its modules"
    fi

    # Overlay lines have to be usable by the kernel's scripts/config.
    bad=0
    while read -r line; do
        [ -n "$line" ] || continue
        case "$line" in
            CONFIG_[A-Z0-9_]*=[ymn]) ;;
            *) printf 'FAIL %s: bad overlay line %s\n' "$fs" "$line"; bad=$((bad + 1)) ;;
        esac
    done <<EOF
$FS_CONFIG_OVERLAY
EOF
    if [ "$bad" = 0 ]; then
        ok "$fs: kernel config overlay is well formed"
    else
        fail=$((fail + bad))
    fi

    # The QPKG configuration and the filesystem definition describe the same
    # package; a mismatch here would ship a package that cannot find itself.
    cfg="$REPO_DIR/fs/$fs/qpkg/qpkg.cfg"
    check "$fs: qpkg.cfg exists" test -f "$cfg"
    check "$fs: qpkg.cfg names the same package" \
        grep -qx "QPKG_NAME=\"$PKG_ID\"" "$cfg"
    check "$fs: qpkg.cfg carries the same version" \
        grep -qx "QPKG_VER=\"$PKG_VERSION\"" "$cfg"
    check "$fs: qpkg.cfg names a service program" \
        grep -q '^QPKG_SERVICE_PROGRAM=' "$cfg"
    svc=$(sed -n 's/^QPKG_SERVICE_PROGRAM="\(.*\)"/\1/p' "$cfg")
    check "$fs: the service program ships in the payload" \
        test -f "$REPO_DIR/shared/$svc"
    check "$fs: package_routines exists" test -f "$REPO_DIR/fs/$fs/qpkg/package_routines"
    check "$fs: package_routines uses the same package name" \
        grep -q "^QPKG_NAME=\"$PKG_ID\"" "$REPO_DIR/fs/$fs/qpkg/package_routines"

    # Nothing may hardcode the kernel release: it is read from the tree.
    if grep -rn '5\.10\.60' "$REPO_DIR/fs/$fs" "$REPO_DIR/shared" "$REPO_DIR/scripts" >/dev/null 2>&1; then
        no "$fs: no hardcoded kernel release in the sources"
    else
        ok "$fs: no hardcoded kernel release in the sources"
    fi
done

printf '\nrepo: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
