# qnap-extra-fs

Filesystem support for QNAP's kernel: the modules QTS does not ship, plus the
matching userspace tools.

This is a set of building blocks. The packages install files and put the
userspace tools on `PATH`; they do not load modules, start services, hook into
boot, import pools, or touch anything else on the NAS.

| | modules | userspace |
|---|---|---|
| **btrfs** | `btrfs.ko`, `zstd_compress.ko`, `xxhash_generic.ko`, `blake2b_generic.ko` | `btrfs`, `mkfs.btrfs`, `btrfsck`, `btrfstune`, `btrfs-image`, `btrfs-map-logical`, `btrfs-select-super`, `fsck.btrfs` |
| **zfs** | not yet — see [Status](#status) | |

Each filesystem produces two packages that carry the same payload: a QPKG
(`QNAP_Btrfs`) for App Center, and a plain tarball for the path without it.

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
containers/               the two build containers
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

**btrfs**: built, packaged and checked offline. Not yet verified on the NAS —
the steps to run there are:

```sh
./load.sh
extrafs.sh status
# a file-backed filesystem, then mount it and prove zstd works
truncate -s 1G /share/Public/btrfs-test.img
mkfs.btrfs /share/Public/btrfs-test.img
mkdir -p /mnt/btrfs-test && mount -o loop,compress=zstd /share/Public/btrfs-test.img /mnt/btrfs-test
btrfs subvolume create /mnt/btrfs-test/sub
btrfs subvolume snapshot /mnt/btrfs-test/sub /mnt/btrfs-test/snap
umount /mnt/btrfs-test
```

**zfs**: not attempted yet. QNAP publishes their own ZFS port in the QuTS Hero
GPL drops (`zol_h520_GPL_code_beta.tar`, `zol_h520_CDDL_code_beta.tar`), but it
is FreeBSD's ZFS/DTrace code grafted onto Linux with a renamed SPL (`lpl/`) and
ships no build system, so it is not a buildable base. The plan is upstream
OpenZFS 2.1.x against the QNAP tree, with those dumps as reference, and to drop
zfs rather than ship something that cannot work.

## Appendix: using this with LXD

*Personal usage notes. The packages are unrelated to LXD and contain nothing
LXD-specific; this section is about how I happen to use them.*

To be written once the packages are verified on the NAS.
