# Build container for OpenZFS: kernel modules and userspace.
#
# OpenZFS brings its own SPL, crypto, zstd and lua, so the kernel side needs
# nothing but a prepared QNAP kernel tree and a normal toolchain - which the
# modules get from the shared builder image. This image is for the userspace,
# which is linked statically because the NAS runs glibc 2.21.
#
# Ubuntu 20.04 again: the toolchain era of QNAP's 5.10 kernel, and old enough
# that its libraries still ship static variants.
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
        libssl-dev \
        libtirpc-dev \
        libtool \
        pkg-config \
        python3 \
        uuid-dev \
        xz-utils \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
