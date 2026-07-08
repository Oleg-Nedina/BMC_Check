# CloudLab SUT Setup Configuration

This document lists the correct sequence of setup and compilation commands we executed on the SUT node to prepare the BMC kernel cache and Memcached servers.

We provide both the local command version (which we run from our control terminal using the SSH shortcut `sut`) and the on-node version (which we run directly inside the SUT shell).

## Identifying the Experiment Interface
To determine which interface is used for the private Experiment Network, we run the following commands.

For the local command version, we execute:
```bash
ssh sut "ip -4 addr"
```
For the on-node version, we run:
```bash
ip -4 addr
```
We look for the interface with the private IP `10.10.1.x` (such as `ens1f1np1`) and make sure not to use the public control network interface.

## System Dependencies Installation
We install the compilers, dependencies, and diagnostic libraries.

For the local command version, we run:
```bash
ssh sut "sudo apt update && sudo apt install -y build-essential clang llvm libelf-dev libevent-dev autoconf automake libtool libmemcached-tools flex bison libssl-dev bc"
```
For the on-node version, we execute:
```bash
sudo apt update && sudo apt install -y build-essential clang llvm libelf-dev libevent-dev autoconf automake libtool libmemcached-tools flex bison libssl-dev bc
```

## Clone the BMC Cache Repository
We clone the repository in the SUT home directory.

For the local command version, we run:
```bash
ssh sut "git clone https://github.com/Orange-OpenSource/bmc-cache.git ~/bmc-cache"
```
For the on-node version, we execute:
```bash
git clone https://github.com/Orange-OpenSource/bmc-cache.git ~/bmc-cache
```

## Download and Prepare the Kernel Sources
We download the required legacy v5.3 kernel source from the official mirrors archive and extract it.

For the local command version, we run:
```bash
ssh sut "wget -O ~/bmc-cache/linux-5.3.tar.xz https://mirrors.edge.kernel.org/pub/linux/kernel/v5.x/linux-5.3.tar.xz && cd ~/bmc-cache && ./kernel-src-prepare.sh"
```
For the on-node version, we run:
```bash
wget -O ~/bmc-cache/linux-5.3.tar.xz https://mirrors.edge.kernel.org/pub/linux/kernel/v5.x/linux-5.3.tar.xz
cd ~/bmc-cache
./kernel-src-prepare.sh
```

## Copy the Local Corrected Code to SUT
We transfer our local modified `bmc_kern.c` (containing the verifier and loop complexity fixes) from our local workspace to the remote SUT.

From our local terminal inside `/home/olly/UNI/NetCmp/`, we execute:
```bash
scp bmc-cache/bmc/bmc_kern.c sut:~/bmc-cache/bmc/bmc_kern.c
```

## Compile BMC Loader and eBPF Programs
We build the user-space loader and compile `bmc_kern.c` into BPF bytecode targets.

For the local command version, we run:
```bash
ssh sut "cd ~/bmc-cache/bmc && make CLANG=clang LLC=llc"
```
For the on-node version, we execute:
```bash
cd ~/bmc-cache/bmc
make CLANG=clang LLC=llc
```

## Compile Memcached Binaries (SO_REUSEPORT and Vanilla)
We compile both the `memcached` (with `SO_REUSEPORT` enabled) and `memcached-vanilla` (without `SO_REUSEPORT`) binaries.

For the local command version, we run:
```bash
ssh sut "cd ~/bmc-cache/memcached-sr && ./autogen.sh && CC=clang CFLAGS='-DREUSEPORT_OPT=1 -Wno-deprecated-declarations -Wno-error' ./configure && make CFLAGS='-O2 -DREUSEPORT_OPT=1 -Wno-deprecated-declarations -Wno-error -fcommon' && mv memcached memcached-sr-bin && make clean && CC=clang CFLAGS='-Wno-deprecated-declarations -Wno-error' ./configure && make CFLAGS='-O2 -Wno-deprecated-declarations -Wno-error -fcommon' && mv memcached memcached-vanilla && mv memcached-sr-bin memcached"
```
For the on-node version, we run:
```bash
cd ~/bmc-cache/memcached-sr
./autogen.sh

# Build reuseport version (memcached)
CC=clang CFLAGS="-DREUSEPORT_OPT=1 -Wno-deprecated-declarations -Wno-error" ./configure
make CFLAGS="-O2 -DREUSEPORT_OPT=1 -Wno-deprecated-declarations -Wno-error -fcommon"
mv memcached memcached-sr-bin

# Build vanilla version (memcached-vanilla)
make clean
CC=clang CFLAGS="-Wno-deprecated-declarations -Wno-error" ./configure
make CFLAGS="-O2 -Wno-deprecated-declarations -Wno-error -fcommon"
mv memcached memcached-vanilla

# Restore reuseport version
mv memcached-sr-bin memcached
```

We verify that both executables are present.

For the local command version, we run:
```bash
ssh sut "ls -lh ~/bmc-cache/memcached-sr/memcached ~/bmc-cache/memcached-sr/memcached-vanilla"
```
For the on-node version, we run:
```bash
ls -lh memcached memcached-vanilla
```
