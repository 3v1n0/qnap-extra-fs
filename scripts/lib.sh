#!/usr/bin/env bash
#
# Shared helpers for the build scripts.

set -euo pipefail

REPO_DIR=${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}

# The kernel release is never hardcoded: it is read back from the QNAP kernel
# tree (scripts/kernel-release.sh), recorded in each built package and
# cross-checked against the NAS at install time.
QTS_GPL_DEFAULT=${QTS_GPL_DEFAULT:-5.2.3.20250218}
KERNEL_MAJOR_DEFAULT=${KERNEL_MAJOR_DEFAULT:-5.10}

# Where the GPL archives are looked for and downloaded to. Point this at
# another checkout's download directory to reuse its archives.
GPL_CACHE_DIR=${GPL_CACHE_DIR:-$REPO_DIR/build/src/gpl}

# QNAP model whose kernel configuration the modules are built against. The
# kernel release itself is never hardcoded: it is read from the tree.
MODEL_DEFAULT=${MODEL_DEFAULT:-TS-X53II}

log() { printf '==> %s\n' "$*" >&2; }
warn() { printf '!!! %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

src_dir() { printf '%s/build/src' "$REPO_DIR"; }
build_dir() { printf '%s/build' "$REPO_DIR"; }
kernel_tree() { printf '%s/GPL_QTS/src/linux-%s' "$(src_dir)" "${KERNEL_MAJOR:-$KERNEL_MAJOR_DEFAULT}"; }
kernel_cfg_dir() { printf '%s/GPL_QTS/kernel_cfg' "$(src_dir)"; }
out_dir() { printf '%s/out' "$REPO_DIR"; }
modules_dir() { printf '%s/build/modules' "$REPO_DIR"; }

# gpl_parts RELEASE -> the download URLs for a GPL release, in order.
# RELEASE looks like 5.2.3.20250218 and is published under "QTS 5.2.3/".
gpl_parts() {
    local rel=$1 qts base
    qts=$(printf '%s' "$rel" | cut -d. -f1-3)
    base="https://sourceforge.net/projects/qosgpl/files/QNAP%20NAS%20GPL%20Source/QTS%20${qts}"
    printf '%s/QTS_Kernel_%s.0.tar.gz/download\n' "$base" "$rel"
    printf '%s/QTS_Kernel_%s.1.tar.gz/download\n' "$base" "$rel"
}

# fs_list -> the filesystems this repository knows how to build.
fs_list() {
    local f
    for f in "$REPO_DIR"/fs/*/fs.mk; do
        [ -f "$f" ] || continue
        basename "$(dirname "$f")"
    done
}

# fs_load NAME -> source fs/<name>/fs.mk into the caller, with a sanity check.
# Everything that differs between filesystems lives in that one file.
fs_load() {
    local name=$1
    FS_NAME=$name
    FS_DIR="$REPO_DIR/fs/$name"
    [ -f "$FS_DIR/fs.mk" ] ||
        die "unknown filesystem '$name' (known: $(fs_list | paste -sd' ' -))"
    . "$FS_DIR/fs.mk"
    : "${FS_TITLE:?fs.mk must set FS_TITLE}"
    : "${PKG_ID:?fs.mk must set PKG_ID}"
    : "${PKG_VERSION:?fs.mk must set PKG_VERSION}"
    export FS_NAME FS_DIR FS_TITLE PKG_ID PKG_VERSION
}

# vermagic KO -> the vermagic recorded inside a built module.
vermagic_of() {
    modinfo -F vermagic "$1" 2>/dev/null || true
}

# kernel_arch: translate uname -m into the name kbuild wants for ARCH=.
# Note the kernel calls 64-bit ARM "arm64" while uname reports "aarch64".
kernel_arch() {
    case "$(uname -m)" in
        x86_64) printf 'x86_64' ;;
        aarch64) printf 'arm64' ;;
        armv7l | armv8l | armv6l) printf 'arm' ;;
        i686 | i586 | i386) printf 'x86' ;;
        *) uname -m ;;
    esac
}

# Ubuntu 20.04 / gcc 9 is the toolchain era of QNAP's 5.10 kernel and avoids
# the breakage newer gcc versions cause on 5.10 headers. It has nothing to do
# with the module ABI: QNAP kernels have CONFIG_MODVERSIONS off, so only the
# vermagic string matters.
BUILD_IMAGE=${BUILD_IMAGE:-localhost/qnap-extrafs-builder:20.04}

# ensure_image IMAGE CONTAINERFILE [extra podman build flags...]
# Rebuilds when the Containerfile changed: a stale image would silently keep
# building with the old definition.
ensure_image() {
    local image=$1 containerfile=$2
    shift 2

    local stamps="$REPO_DIR/build/images"
    local stamp="$stamps/$(printf '%s' "$image" | tr ':/' '__').stamp"
    local hash
    hash=$(sha256sum "$containerfile" | cut -d' ' -f1)

    if sudo podman image exists "$image" 2>/dev/null &&
        [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$hash" ]; then
        return 0
    fi

    log "building container image $image"
    # pasta (podman's default network) is broken in this environment; the
    # builds need the network for apt/apk and for the source tarballs.
    sudo podman build -q --network host -t "$image" "$@" \
        -f "$containerfile" "$(dirname "$containerfile")"

    mkdir -p "$stamps"
    printf '%s\n' "$hash" > "$stamp"
}
