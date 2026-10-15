# qnap-extra-fs

Filesystem support for QNAP's kernel: the modules QTS does not ship, plus the
matching userspace tools.

This is a set of building blocks. The packages install files and put the
userspace tools on `PATH`; they do not load modules, start services, hook into
boot, import pools, or touch anything else on the NAS.

| | modules | userspace |
|---|---|---|
| **btrfs** | `btrfs.ko`, `zstd_compress.ko`, `xxhash_generic.ko`, `blake2b_generic.ko` | `btrfs`, `mkfs.btrfs`, `btrfsck`, `btrfstune`, `btrfs-image`, `btrfs-map-logical`, `btrfs-select-super`, `fsck.btrfs` |
| **zfs** | `zfs.ko`, `spl.ko`, `zcommon.ko`, `znvpair.ko`, `zavl.ko`, `icp.ko`, `zlua.ko`, `zunicode.ko`, `zzstd.ko` | `zpool`, `zfs`, `mount.zfs`, `zdb`, `zstream`, `zgenhostid`, `fsck.zfs` |

Each filesystem produces two packages that carry the same payload: a QPKG
(`QNAP_Btrfs`, `QNAP_ZFS`) for App Center, and a plain tarball for the path
without it.

## Why the userspace is built static

The NAS runs **glibc 2.21** (2015). Anything dynamically linked would have to
be built with a matching-or-older toolchain — Debian 8 or CentOS 7 era — which
is a lot of archaeology for no benefit. Linking statically removes the question
entirely: every tool is a single file with no libraries to ship and no libc
version to match.

The tools are built in the same Ubuntu 20.04 / gcc 9 container as the modules,
against glibc's static libc. musl was tried first and dropped on the evidence:
it has neither `struct stat64` nor `pread64`, both of which btrfs-progs uses,
and Alpine's static `libblkid` — which btrfs-progs requires — needs `libeconf`,
for which Alpine ships no static library at all.

## Building

Prerequisites: `podman` (run through `sudo`), a few GB of disk for the kernel
tree and the build containers, and network access on the first run.

```sh
./build.sh                    # everything: fetch, modules, tools, packages
./build.sh fetch              # just QNAP's GPL kernel source
./build.sh btrfs              # modules + tools + package for one filesystem
./build.sh btrfs modules      # a single step
./build.sh btrfs tools
./build.sh btrfs package
./build.sh test               # every check that does not need the NAS
./build.sh clean
```

| Variable | Meaning |
|---|---|
| `MODEL` | QNAP model whose kernel configuration to build against (default `TS-X53II`) |
| `KERNEL_RELEASE` | assert a specific release instead of the tree's own |
| `QTS_GPL` | QNAP GPL release to fetch (default `5.2.3.20250218`) |
| `GPL_CACHE_DIR` | where the GPL archives live; point it at another checkout to reuse them |

The kernel release is never hardcoded. It is read from the extracted tree
(`scripts/kernel-release.sh`), recorded in the package, and checked against the
NAS when the modules are loaded.

### How the modules are built

1. **Configure the tree.** The model's `.config` goes into the tree, the
   filesystem's overlay (`fs/<name>/fs.mk`) is applied with the kernel's own
   `scripts/config`, and `olddefconfig` resolves the symbols it selects. The
   result is checked against an explicit list of expected symbols, so a config
   change fails the build instead of quietly shipping a module with features
   missing.
2. **Prepare and build.** `modules_prepare` regenerates the headers the module
   Makefiles read, then each module is built out of tree (`M=<dir> <name>.ko`).
   That form is used because the configuration has to be overridden per module,
   and because it is the only way a partial build can resolve a reference from
   one module to another: `KBUILD_EXTRA_SYMBOLS` carries the symbols of the
   modules built before it. `fs.mk` therefore lists the modules in dependency
   order.
3. **Collect the closure.** The load order is derived from `modinfo -F depends`
   on the built modules, and a dependency the package does not build is a hard
   error. The vermagic of every module is checked against the target release —
   QNAP kernels have `CONFIG_MODVERSIONS` off, so that string is the whole ABI.

The kernel itself is never built.

## Installing

**QPKG** (App Center, or from a shell):

```sh
scp out/QNAP_Btrfs_1.0.0.qpkg admin@nas:/share/Public/
ssh admin@nas 'sudo sh /share/Public/QNAP_Btrfs_1.0.0.qpkg'
```

There is nothing to start afterwards: the service program does nothing, so
enabling the package in App Center runs nothing.

**Tarball** (no App Center):

```sh
scp out/qnap-btrfs-5.10.60-qnap.tar.gz admin@nas:/share/Public/
ssh admin@nas 'cd /share/Public && tar xzf qnap-btrfs-5.10.60-qnap.tar.gz && sudo ./qnap-btrfs/install.sh'
```

Either way, installation does exactly two things: puts the files in place and
symlinks the userspace tools into `/usr/local/bin`. It does not load a module
or write to boot configuration. The QPKG does ship a service program, but only
because QTS's installer will not work without one — that script does nothing,
so enabling the package in App Center starts nothing.

## Loading the modules

```sh
./load.sh              # insmod every module, in the recorded order
./unload.sh            # rmmod them again, in reverse order
./extrafs.sh status    # what is loaded and what is not
./extrafs.sh list      # the modules, in load order
```

The modules are loaded straight from the package directory, so nothing is
copied into `/lib/modules`. That also means the kernel cannot auto-load them:
`modprobe btrfs` will not find them and mounting a btrfs filesystem will not
pull the module in by itself. Load them first; wire `load.sh` into your own
startup sequence if you want that to happen automatically.

**After a QTS update** the kernel release changes and the modules no longer
match. Rebuild for the new release and reinstall:

```sh
./build.sh btrfs modules --kernel-release "$(ssh admin@nas uname -r)"
```

## What each filesystem needs

### btrfs

* `CONFIG_BTRFS_FS=m` and `CONFIG_BTRFS_FS_POSIX_ACL=y`. `olddefconfig` then
  resolves `ZSTD_COMPRESS=m`, `CRYPTO_XXHASH=m` and `CRYPTO_BLAKE2B=m`.
* QNAP's kernel has the zstd **de**compressor built in but not the compressor,
  and btrfs always calls into it, so `zstd_compress.ko` ships in the package
  even though it is not a feature anyone asks for by name. The xxhash and
  blake2b modules are there because btrfs reaches those checksums through the
  crypto API by name rather than by symbol.
* Userspace is btrfs-progs **5.16.2**, contemporary with the 5.10 kernel: its
  `mkfs.btrfs` defaults are guaranteed mountable by 5.10, and every ioctl the
  tools use exists in that kernel. It is built with backtrace, NLS, zoned (SMR)
  and `btrfs-convert` support disabled, none of which this package needs.

### zfs

* Nothing from the kernel configuration: OpenZFS brings its own SPL, crypto,
  zstd and lua, and its `configure` checks the kernel for what it needs.
* Modules and userspace both come from OpenZFS **2.1.15**, configured against
  the QNAP tree. 2.1.x is the last series that supports the 5.10 kernel and
  whose userspace ioctls match it.
* QNAP does publish their own ZFS port, in the QuTS Hero GPL drops
  (`zol_h520_GPL_code_beta.tar`, `zol_h520_CDDL_code_beta.tar`), but it is
  FreeBSD's ZFS and DTrace grafted onto Linux with a renamed SPL (`lpl/`) and
  it ships no build system, so it is reference only.
* The userspace is static too, which needs libtool's `-all-static`: plain
  `-static` is ignored on the libtool link line, and the first attempt produced
  dynamically linked binaries because of it.
* `zpool` writes its cache to `/etc/zfs/zpool.cache`. The package does not
  create that directory (it installs files and nothing else), so if `zpool`
  complains about it, `mkdir -p /etc/zfs` once.
* `/dev/zfs` is created by the module. If it is missing, `grep zfs /proc/misc`
  gives the minor number and `mknod /dev/zfs c 10 <minor>` creates it.

## Known issues

**Both filesystems crash the NAS on the first real write.** btrfs panicked on
`btrfs subvolume create` on a loop-mounted image; zfs took the machine down
while writing a file into a dataset, with pool and dataset creation and the
mount itself working fine. Two independent filesystems failing the same way is
not two filesystem bugs — it points at the modules not matching the kernel they
are loaded into.

The evidence that fits: the newest QTS source QNAP publishes is **5.2.3**
(`5.2.3.20250218`, whose kernel was built `Tue Feb 18 07:40:22 CST 2025`) while
this NAS runs **5.2.10**. The release string is `5.10.60-qnap` either way, so
vermagic cannot detect the difference, but a kernel patched after the drop
would give modules built against the older headers mismatched structure
layouts.

Confirmed on this NAS: `cat /proc/version` reports

```
#1 SMP Fri Jul 31 00:56:17 CST 2026
```

while the newest source QNAP publishes (`QTS_Kernel_5.2.3.20250218`) was built
`Tue Feb 18 07:40:22 CST 2025`. The kernel this NAS runs was rebuilt 17 months
later and the release string is identical on both sides, so nothing in these
packages can detect the difference: they were compiled against headers that no
longer match the running kernel, which corrupts memory in code that allocates
and does heavy I/O — btrfs and zfs — while leaving simple modules (vsock)
working.

So the modules cannot be built correctly for this NAS until QNAP publishes the
source for the kernel they actually ship. Their SourceForge project stops at
QTS 5.2.3, and the NAS has no `/proc/config.gz`, so the configuration cannot be
recovered either. Ask QNAP support for the GPL source of this QTS build: they
are obliged to provide it. The build takes the release as a parameter
(`QTS_GPL=... ./build.sh`), so once that source exists the packages rebuild in
minutes.

The alternative is running a QTS release whose source is published (5.2.3),
which is a much bigger decision than waiting.

Until then, do not load these modules on a NAS that matters: each attempt risks
the machine and its data.

**VMs on a ZFS pool need `/dev/zvol/<pool>/<vol>` symlinks**, which udev
creates. On a system without udev the zvol device exists but not the symlink
LXD's zfs driver looks for, so datasets (containers) are fine while VM disks
are not.

## Repository layout

```
build.sh                  entry point (./build.sh <fs> <step>)
scripts/                  shared build framework
  lib.sh                  helpers, fs.mk loading, container image handling
  00-fetch-gpl.sh         QNAP GPL source, plus a pristine Module.symvers
  10.. kernel-release.sh  the release, read from the tree
  20-make-modules.sh      modules, in the build container
  30-make-tools.sh        userspace, in the tools container
  40-make-package.sh      QPKG + tarball
  in-container/           the parts that run inside the containers
containers/               the build containers
fs/<name>/fs.mk           everything that differs between filesystems
fs/<name>/qpkg/           qpkg.cfg and package_routines
shared/                   installed verbatim by every package: extrafs.sh,
                          extrafs-service.sh, load.sh, unload.sh, install.sh,
                          uninstall.sh
tests/                    offline checks
out/                      packages (built)
```

## Tests

`./build.sh test` runs everything that does not need the NAS:

* repository checks: the build scripts parse, each `fs.mk` is well formed, and
  `qpkg.cfg` / `package_routines` agree with it;
* package checks: payload layout, every tool present and statically linked,
  vermagic of every module, the load order satisfying every dependency, module
  checksums, `extrafs.sh list` matching the order file, `status` refusing a
  kernel it has no modules for, and an end-to-end `install.sh` / `uninstall.sh`
  run in a throwaway container.

What they cannot check is whether the modules actually load and work: that
needs the NAS, and is the first thing to try after installing.

## Status

**btrfs**: built, packaged and checked offline. On the NAS, loading worked,
`mkfs.btrfs` worked and the filesystem mounted — then creating a subvolume
panicked the kernel (see [Known issues](#known-issues)), so it is not verified
end to end yet. The steps, once that is understood:

```sh
cd /share/Public/qnap-btrfs
sudo ./install.sh && sudo ./load.sh && ./extrafs.sh status
mkdir -p "$PWD/btrfs-test/mnt"
dd if=/dev/zero of="$PWD/btrfs-test/test.img" bs=1M count=0 seek=256
sudo mkfs.btrfs -f "$PWD/btrfs-test/test.img"
sudo mount -t btrfs -o loop,compress=zstd "$PWD/btrfs-test/test.img" "$PWD/btrfs-test/mnt"
sudo btrfs subvolume create "$PWD/btrfs-test/mnt/sub"
sudo btrfs subvolume snapshot "$PWD/btrfs-test/mnt/sub" "$PWD/btrfs-test/mnt/snap"
sudo umount "$PWD/btrfs-test/mnt"
```

**zfs**: modules and userspace build and the packages are produced; nothing has
been loaded on the NAS yet. The steps there:

```sh
cd /share/Public/qnap-zfs
sudo ./install.sh && sudo ./load.sh && ./extrafs.sh status
mkdir -p "$PWD/zfs-test"
dd if=/dev/zero of="$PWD/zfs-test/pool.img" bs=1M count=0 seek=512
sudo zpool create -f -m none testpool "$PWD/zfs-test/pool.img"
sudo zfs create -o mountpoint="$PWD/zfs-test/data" testpool/data
sudo sh -c "echo hello > '$PWD/zfs-test/data/hello'"
sudo zfs snapshot testpool/data@snap
sudo zfs list -r testpool
sudo zfs destroy testpool/data@snap && sudo zfs destroy testpool/data
sudo zpool destroy testpool
sudo rm -rf "$PWD/zfs-test"
```

Test in a directory on the volume you are working in, not in `/tmp`: on QTS
that is a small RAM filesystem, and a file-backed pool does not fit.

## Appendix: using this with LXD

*Personal usage notes. The packages are unrelated to LXD and contain nothing
LXD-specific; this section is about how I happen to use them.*

To be written once the packages are verified on the NAS.
