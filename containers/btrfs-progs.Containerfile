# Build container for the filesystem userspace tools.
#
# Everything is linked statically, because the NAS runs glibc 2.21: a static
# binary has no libc version to match and no libraries to ship.
#
# Ubuntu 20.04 is used for the same reason the module build uses it - it is
# the toolchain era of QNAP's 5.10 kernel - and because its libblkid has no
# libeconf dependency, which Alpine's static libblkid does (and Alpine has no
# static libeconf at all). musl also lacks struct stat64 and pread64, both of
# which btrfs-progs uses.
FROM ubuntu:20.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        autoconf \
        automake \
        bash \
        build-essential \
        ca-certificates \
        curl \
        file \
        libblkid-dev \
        liblzo2-dev \
        libtool \
        libzstd-dev \
        pkg-config \
        uuid-dev \
        xz-utils \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
