FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

ARG VERILATOR_REF=stable
ARG ICARUS_REF=master
ARG RISCV_ARCH=rv32ima
ARG RISCV_ABI=ilp32

ENV DEBIAN_FRONTEND=noninteractive

# ------------------------------------------------------------------
# Common build tooling + deps for Verilator and riscv-gnu-toolchain
# ------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    curl \
    ca-certificates \
    make \
    cmake \
    ninja-build \
    autoconf \
    automake \
    autotools-dev \
    libtool \
    gawk \
    bison \
    flex \
    texinfo \
    gperf \
    patchutils \
    bc \
    help2man \
    perl \
    python3 \
    python3-pip \
    zlib1g-dev \
    libexpat-dev \
    libmpc-dev \
    libmpfr-dev \
    libgmp-dev \
    libfl2 \
    libfl-dev \
    liblz4-dev \
    ccache \
    libjemalloc-dev \
    numactl \
    gtkwave \
    device-tree-compiler \
 && rm -rf /var/lib/apt/lists/*

# ------------------------------------------------------------------
# Verilator - build latest stable release from source
# ------------------------------------------------------------------
RUN git clone --depth 1 --branch ${VERILATOR_REF} https://github.com/verilator/verilator /tmp/verilator \
 && cd /tmp/verilator \
 && autoconf \
 && ./configure \
 && make -j"$(nproc)" \
 && make install \
 && rm -rf /tmp/verilator

# ------------------------------------------------------------------
# Icarus Verilog - build from source (packaged apt version lags
# behind the SystemVerilog support this project's RTL/TB rely on)
# ------------------------------------------------------------------
RUN git clone --depth 1 --branch ${ICARUS_REF} https://github.com/steveicarus/iverilog /tmp/iverilog \
 && cd /tmp/iverilog \
 && sh autoconf.sh \
 && ./configure --prefix=/usr/local \
 && make -j"$(nproc)" \
 && make install \
 && rm -rf /tmp/iverilog

# ------------------------------------------------------------------
# RISC-V GNU toolchain - bare-metal newlib, rv32ima/ilp32
# ------------------------------------------------------------------
RUN git clone https://github.com/riscv-collab/riscv-gnu-toolchain /tmp/riscv-gnu-toolchain \
 && cd /tmp/riscv-gnu-toolchain \
 && ./configure --prefix=/opt/riscv --with-arch=${RISCV_ARCH} --with-abi=${RISCV_ABI} --disable-linux \
 && make -j"$(nproc)" \
 && rm -rf /tmp/riscv-gnu-toolchain
ENV PATH="/opt/riscv/bin:${PATH}"

# ------------------------------------------------------------------
# Xilinx tools (Vivado, xsdb, ...) are NOT installed in this image: the
# host's existing install is bind-mounted in by devcontainer.json at
# $XILINX_ROOT. This section only adds what is needed to run them from
# here: a few runtime libraries the base image lacks, a serial terminal,
# USB/serial access for the vscode user, and launcher commands on PATH
# (see .devcontainer/xilinx-tool).
#
# Kept at the end of the file so the long toolchain builds above stay
# cached when this section changes.
# ------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    libxtst6 \
    libncurses6 \
    libusb-1.0-0 \
    usbutils \
    picocom \
 && rm -rf /var/lib/apt/lists/* \
 && usermod -aG dialout,plugdev vscode

COPY .devcontainer/xilinx-tool /usr/local/bin/xilinx-tool
RUN chmod 755 /usr/local/bin/xilinx-tool \
 && for t in vivado xsdb hw_server bootgen updatemem; do \
        ln -s xilinx-tool /usr/local/bin/$t; \
    done
