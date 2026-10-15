# Btrfs for QNAP's 5.10 kernel.
#
# Everything that differs between the filesystems in this repository lives in
# this file: the modules to build, the kernel configuration they need and the
# userspace that goes with them. scripts/lib.sh sources it (fs_load).

FS_TITLE="Btrfs"

PKG_ID="QNAP_Btrfs"
PKG_DISPLAY="Btrfs filesystem support"
PKG_SUMMARY="Btrfs kernel modules and userspace tools for QTS"
PKG_VERSION="1.0.0"
PKG_AUTHOR="Marco Trevisan"
PKG_LICENSE="GPL-2.0"

# Modules to build, in dependency order: a partial build modposts one module
# at a time, so a module can only link against modules built before it (their
# symbols are passed along with KBUILD_EXTRA_SYMBOLS).
#
# Each line is "<target> [make variables...]". The variables pin the one
# module the directory should produce: btrfs always calls into the kernel's
# zstd compressor (fs/btrfs/zstd.c) and QNAP's kernel has CONFIG_ZSTD_COMPRESS
# off, so that has to come with us, and its directory also holds the
# decompressor, which the kernel already provides.
FS_MODULE_TARGETS="
lib/zstd/zstd_compress.ko CONFIG_ZSTD_COMPRESS=m CONFIG_ZSTD_DECOMPRESS=n
fs/btrfs/btrfs.ko CONFIG_BTRFS_FS=m CONFIG_BTRFS_FS_POSIX_ACL=y
"

# Modules that are not link dependencies but are needed at runtime, so they
# are shipped and loaded as well: btrfs reaches xxhash and blake2b through the
# crypto API by name, and QNAP's kernel has CRYPTO_XXHASH/CRYPTO_BLAKE2B off.
FS_EXTRA_MODULES="
crypto/xxhash_generic.ko
crypto/blake2b_generic.ko
"

# Kernel configuration applied on top of the model's .config.
FS_CONFIG_OVERLAY="
CONFIG_BTRFS_FS=m
CONFIG_BTRFS_FS_POSIX_ACL=y
"

# What .config must contain after olddefconfig. BTRFS_FS selects the zstd
# compressor and the two checksum algorithms; if a future QNAP config stops
# offering them this fails the build, rather than shipping a btrfs with
# features quietly missing.
FS_CONFIG_EXPECT="
CONFIG_BTRFS_FS=m
CONFIG_BTRFS_FS_POSIX_ACL=y
CONFIG_ZSTD_COMPRESS=m
CONFIG_CRYPTO_XXHASH=m
CONFIG_CRYPTO_BLAKE2B=m
"

# Userspace, built static (musl): the NAS runs glibc 2.21, so dynamically
# linked binaries would have to be built with a 2015 toolchain.
FS_TOOLS_VERSION="5.16.2"
FS_TOOLS_URL="https://mirrors.edge.kernel.org/pub/linux/kernel/people/kdave/btrfs-progs/btrfs-progs-v${FS_TOOLS_VERSION}.tar.xz"
FS_TOOLS_SHA256="9e9b303a1d0fd9ceaaf204ee74c1c8fa1fd55794e223d9fe2bc62875ecbd53d2"
FS_TOOLS_IMAGE="localhost/qnap-extrafs-btrfs-tools:20.04"
FS_TOOLS_CONTAINERFILE="containers/btrfs-progs.Containerfile"
FS_TOOLS_SCRIPT="scripts/in-container/build-btrfs-progs.sh"
FS_TOOLS_BIN="btrfs mkfs.btrfs btrfsck btrfstune btrfs-image btrfs-map-logical btrfs-select-super fsck.btrfs"
