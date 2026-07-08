# BMC Fork and Modification Note

This directory contains a fork of the official repository for the NSDI '21 paper "BMC: Accelerating Memcached using Safe In-Kernel Caching". Please note that this codebase is a third-party framework; it was not designed by us, and we are not responsible for its original implementation or dependency constraints.

To adapt the legacy codebase for modern compilers (specifically LLVM/Clang version 14 or higher), we applied a key compatibility patch inside [bmc/bmc_kern.c](file:///home/olly/UNI/NetCmp/BMC_Check/bmc-cache_NC/bmc/bmc_kern.c). The original whitespace-skipping loop triggered aggressive loop unrolling in modern compiler versions, which invalidated packet bounds checks and caused the Linux kernel verifier to reject the eBPF bytecode. We replaced that loop with a compiler-friendly bounded iteration matching the data bounds of the network descriptor, which resolves the verifier's safety checks and allows successful compilation and deployment.

***

### __Code for the [NSDI'21 paper](https://www.usenix.org/system/files/nsdi21-ghigoff.pdf) *"BMC: Accelerating Memcached using Safe In-kernel Caching and Pre-stack Processing"*.__

BibTex entry available [here](#cite-this-work).

BMC (BPF Memory Cache) is an in-kernel cache for memcached. It enables runtime, crash-safe extension of the Linux kernel to process specific memcached requests before the execution of the standard network stack. BMC does not require modification of neither the Linux kernel nor the memcached application. Running memcached with BMC improves throughput by up to 18x compared to the vanilla memcached application.

Requirements
---

Linux kernel __v5.3__ or higher is required to run BMC.

Other software dependencies are required to build BMC and Memcached-SR (see [Building BMC](#building-bmc) and [Building Memcached-SR](#building-memcached-sr)). 

Build instructions
---

### Building BMC

BMC must be compiled with libbpf and other header files obtained from kernel sources. The project does not include the kernel sources, but the [kernel-src-download.sh](kernel-src-download.sh) and [kernel-src-prepare.sh](kernel-src-prepare.sh) scripts automate the download of the kernel sources and prepare them for the compilation of BMC.

These scripts require the following software to be installed:

```sh
gpg curl tar xz make gcc flex bison libssl-dev libelf-dev
```

The project uses llvm and clang version 9 to build BMC, but more recent versions might work as well:

```sh
llvm-9 clang-9
```

Note that ```libelf-dev``` is also required to build libbpf and BMC.

With the previous software installed, BMC can be built with the following:
```bash
$ ./kernel-src-download.sh
$ ./kernel-src-prepare.sh
$ cd bmc && make
```

After BMC has been successfully built, kernel sources can be removed by running the [kernel-src-remove.sh](kernel-src-remove.sh) script from the project root.

### Building Memcached-SR

Memcached-SR is based on memcached v1.5.19. Building it requires the following software:

```sh
clang-9 (or gcc-9) automake libevent-dev
```

Either ```clang-9``` or ```gcc-9``` is required in order to compile memcached without linking issues. Depending on your distribution, you might also need to use the ```-Wno-deprecated-declarations``` compilation flag.

Memcached-SR can be built with the following:
```bash
$ cd memcached-sr 
$ ./autogen.sh
$ CC=clang-9 CFLAGS='-DREUSEPORT_OPT=1 -Wno-deprecated-declarations' ./configure && make
```

The ```memcached``` binary will be located in the memcached-sr directory.

Further instructions
---

### TC egress hook

BMC doesn't attach the tx_filter eBPF program to the egress hook of TC, it needs to be attached manually.

To do so, you first need to make sure that the BPF filesystem is mounted, if it isn't you can mount it with the following command:
```bash
# mount -t bpf none /sys/fs/bpf/
```

Once BMC is running and the tx\_filter program has been pinned to /sys/fs/bpf/bmc\_tx\_filter, you can attach it using the tc command line:
```bash
# tc qdisc add dev <interface_name> clsact
# tc filter add dev <interface_name> egress bpf object-pinned /sys/fs/bpf/bmc_tx_filter
```

After you are done using BMC, you can detach the program with these commands:
```bash
# tc filter del dev <interface_name> egress
# tc qdisc del dev <interface_name> clsact
```
And unpin the program with ```# rm /sys/fs/bpf/bmc_tx_filter```

License
---

Files under the [bmc](bmc) directory are licensed under the [GNU Lesser General Public License version 2.1](LICENSE).

Files under the [memcached-sr](memcached-sr) directory are licensed under the [BSD-3-Clause BSD](LICENSE&#32;(Memcached&#32;customizations)) license.

Cite this work
---
BibTex:
```
@inproceedings{265047,
	title        = {{BMC}: Accelerating Memcached using Safe In-kernel Caching and Pre-stack Processing},
	author       = {Yoann Ghigoff and Julien Sopena and Kahina Lazri and Antoine Blin and Gilles Muller},
	year         = 2021,
	month        = apr,
	booktitle    = {18th {USENIX} Symposium on Networked Systems Design and Implementation ({NSDI} 21)},
	publisher    = {{USENIX} Association},
	pages        = {487--501},
	isbn         = {978-1-939133-21-2},
	url          = {https://www.usenix.org/conference/nsdi21/presentation/ghigoff}
}
```