# ZFS for QNAP's 5.10 kernel.
#
# ZFS is not in the kernel tree at all, so its modules and its userspace both
# come from upstream OpenZFS, configured against the QNAP kernel tree.
#
# QNAP does publish their own ZFS port in the QuTS Hero GPL drops
# (zol_h520_GPL_code_beta.tar and zol_h520_CDDL_code_beta.tar), but it is
# FreeBSD's ZFS and DTrace grafted onto Linux with a renamed SPL (lpl/) and it
# ships no build system, so it is reference only.

FS_TITLE="ZFS"

PKG_ID="QNAP_ZFS"
PKG_DISPLAY="ZFS filesystem support"
PKG_SUMMARY="ZFS kernel modules and userspace tools for QTS"
PKG_VERSION="1.0.0"
PKG_AUTHOR="Marco Trevisan"
PKG_LICENSE="CDDL-1.0"

# ZFS needs nothing from the kernel configuration: OpenZFS brings its own SPL,
# crypto, zstd and lua, and configure checks the kernel for what it needs.
FS_CONFIG_OVERLAY=""

# OpenZFS 2.1.x: the last series that supports the 5.10 kernel and that has a
# userspace whose ioctls match what a 5.10 kernel expects.
FS_MODULE_VERSION="2.1.15"
FS_MODULE_URL="https://github.com/openzfs/zfs/releases/download/zfs-${FS_MODULE_VERSION}/zfs-${FS_MODULE_VERSION}.tar.gz"
FS_MODULE_SHA256="374f92fde42600103ba4d184cb4841d648b8849320b504d10690f17e30e51ad3"
FS_MODULE_BUILDER="scripts/in-container/build-openzfs-modules.sh"

# The CLIs, minus the daemon (zed) and the udev/initramfs helpers. fsck.zfs is
# the usual "zfs needs no fsck" stub script. zstream replaced zstreamdump in
# 2.1.
FS_TOOLS_VERSION="2.1.15"
FS_TOOLS_URL="$FS_MODULE_URL"
FS_TOOLS_SHA256="$FS_MODULE_SHA256"
FS_TOOLS_IMAGE="localhost/qnap-extrafs-zfs-tools:20.04"
FS_TOOLS_CONTAINERFILE="containers/openzfs.Containerfile"
FS_TOOLS_SCRIPT="scripts/in-container/build-openzfs-tools.sh"
FS_TOOLS_BIN="zpool zfs mount.zfs zdb zstream zgenhostid fsck.zfs"
