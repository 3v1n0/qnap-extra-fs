#!/usr/bin/env bash
#
# Build one filesystem's userspace tools.
#
# Usage: scripts/30-make-tools.sh <fs>
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib.sh"

fs=${1:-}
[ -n "$fs" ] || die "usage: 30-make-tools.sh <fs>"

fs_load "$fs"

ensure_image "$FS_TOOLS_IMAGE" "$REPO_DIR/$FS_TOOLS_CONTAINERFILE"

log "building $FS_TITLE userspace (version $FS_TOOLS_VERSION), static"

sudo podman run --rm \
    --network host \
    --security-opt label=disable \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp -e TMPDIR=/tmp \
    -e FS_NAME="$FS_NAME" \
    -e JOBS="$(nproc)" \
    -v "$REPO_DIR":/work \
    -w /work \
    "$FS_TOOLS_IMAGE" \
    bash "/work/$FS_TOOLS_SCRIPT"
