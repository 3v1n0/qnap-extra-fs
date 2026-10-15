#!/usr/bin/env bash
#
# Build one filesystem's kernel modules for QNAP's kernel.
#
# Usage: scripts/20-make-modules.sh <fs> [--model MODEL] [--kernel-release REL]
#
# MODEL selects the QNAP kernel_cfg directory to configure the tree with.
# KERNEL_RELEASE defaults to the release of the QNAP tree itself; pass it
# explicitly to assert against a specific NAS (e.g. the output of uname -r).
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib.sh"

fs=${1:-}
[ -n "$fs" ] || die "usage: 20-make-modules.sh <fs> [--model MODEL] [--kernel-release REL]"
shift

fs_load "$fs"

MODEL=${MODEL:-$MODEL_DEFAULT}
KERNEL_RELEASE=${KERNEL_RELEASE:-}

while [ $# -gt 0 ]; do
    case "$1" in
        --model) MODEL=$2; shift 2 ;;
        --model=*) MODEL=${1#*=}; shift ;;
        --kernel-release) KERNEL_RELEASE=$2; shift 2 ;;
        --kernel-release=*) KERNEL_RELEASE=${1#*=}; shift ;;
        *) die "unknown argument: $1" ;;
    esac
done

KERNEL_MAJOR=${KERNEL_MAJOR:-$KERNEL_MAJOR_DEFAULT}
TARGET_ARCH=${TARGET_ARCH:-$(kernel_arch)}

ensure_image "$BUILD_IMAGE" "$REPO_DIR/containers/builder.Containerfile"

[ -n "$KERNEL_RELEASE" ] || KERNEL_RELEASE=$("$REPO_DIR/scripts/kernel-release.sh")
log "target kernel release: $KERNEL_RELEASE"
log "filesystem: $FS_TITLE ($FS_NAME)"

sudo podman run --rm \
    --network host \
    --security-opt label=disable \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp -e TMPDIR=/tmp \
    -e FS_NAME="$FS_NAME" \
    -e KERNEL_MAJOR="$KERNEL_MAJOR" \
    -e TARGET_ARCH="$TARGET_ARCH" \
    -e MODEL="$MODEL" \
    -e KERNEL_RELEASE="$KERNEL_RELEASE" \
    -e JOBS="$(nproc)" \
    -v "$REPO_DIR":/work \
    -w /work \
    "$BUILD_IMAGE" \
    bash /work/scripts/in-container/build-modules.sh
