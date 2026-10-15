#!/bin/sh
#
# Install this package on a QNAP NAS without App Center.
#
# Run it from the directory you unpacked the tarball into, as root:
#
#   tar xzf qnap-<fs>-<release>.tar.gz
#   cd qnap-<fs>
#   ./install.sh
#
# The only thing this does is put the userspace tools on PATH, as symlinks
# pointing back into this directory. The kernel modules are not loaded, nothing
# is enabled and nothing is started at boot: run ./load.sh when you want the
# modules in the kernel.
set -eu

self=$(readlink -f "$0" 2>/dev/null || echo "$0")
PREFIX=$(cd "$(dirname "$self")" && pwd)
KVER=$(uname -r)

[ "$(id -u)" = 0 ] || { echo "run me as root" >&2; exit 1; }

# shellcheck source=/dev/null
[ -f "$PREFIX/extrafs.conf" ] && . "$PREFIX/extrafs.conf"
TITLE=${FS_TITLE:-$(basename "$PREFIX")}

echo "Installing the $TITLE userspace tools from $PREFIX"
mkdir -p /usr/local/bin
for tool in "$PREFIX"/bin/*; do
    [ -x "$tool" ] || continue
    ln -sfn "$tool" "/usr/local/bin/$(basename "$tool")"
    echo "    /usr/local/bin/$(basename "$tool") -> $tool"
done

echo
if [ -d "$PREFIX/modules/$KVER" ]; then
    echo "The modules are NOT loaded. To load them:  $PREFIX/load.sh"
    echo "To take them out again:                   $PREFIX/unload.sh"
else
    # The tools are kernel-independent; the modules are not. Say so and carry
    # on rather than refusing to install anything.
    echo "Note: this package carries no modules for kernel $KVER, so only the"
    echo "tools were installed. It carries modules for: $(ls "$PREFIX/modules" 2>/dev/null | tr '\n' ' ')"
    echo "Rebuild them with: ./build.sh ${FS_NAME:-<fs>} modules --kernel-release $KVER"
fi
echo "To see what is loaded:                    $PREFIX/extrafs.sh status"
