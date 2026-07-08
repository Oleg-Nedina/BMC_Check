# Troubleshooting Guide

This directory provides a comprehensive log of the software, build, and runtime issues resolved during the replication and stress testing of BMC. Each issue is documented in a dedicated markdown file detailing the problem, when it was encountered, and the workaround I implemented.

The file [duplicate_globals_linker_failure.md](file:///home/olly/UNI/NetCmp/BMC_Check/troubleshooting/duplicate_globals_linker_failure.md) explains the glibc duplicate symbol linker errors resolved by compiling Memcached with the `-fcommon` flag.

The file [clang_loop_unrolling_verifier_rejection.md](file:///home/olly/UNI/NetCmp/BMC_Check/troubleshooting/clang_loop_unrolling_verifier_rejection.md) details the LLVM/Clang verifier failures resolved by refactoring the whitespace loop inside [bmc_kern.c](file:///home/olly/UNI/NetCmp/BMC_Check/bmc-cache_NC/bmc/bmc_kern.c).

The file [kernel_source_mirror_outage.md](file:///home/olly/UNI/NetCmp/BMC_Check/troubleshooting/kernel_source_mirror_outage.md) describes the kernel source and keyserver mirror outages resolved by redirecting downloads to the edge kernel archives.

The file [memaslap_udp_deadlock.md](file:///home/olly/UNI/NetCmp/BMC_Check/troubleshooting/memaslap_udp_deadlock.md) details the memaslap client-side event loop deadlocks resolved by utilizing a mixed GET/SET workload.

The file [memaslap_client_segfault.md](file:///home/olly/UNI/NetCmp/BMC_Check/troubleshooting/memaslap_client_segfault.md) covers the client-side segmentation faults resolved by pinning thread concurrency.

The file [mellanox_multiget_packet_drops.md](file:///home/olly/UNI/NetCmp/BMC_Check/troubleshooting/mellanox_multiget_packet_drops.md) details the Mellanox ConnectX-5 driver drops resolved by tracing the kernel path using the `pwru` utility.

The file [toeplitz_rss_queue_contention.md](file:///home/olly/UNI/NetCmp/BMC_Check/troubleshooting/toeplitz_rss_queue_contention.md) explains SUT queue contention bottlenecks resolved by manually mapping RX queue interrupt affinities using `ethtool`.

The file [vanilla_memcached_socket_lock_bottleneck.md](file:///home/olly/UNI/NetCmp/BMC_Check/troubleshooting/vanilla_memcached_socket_lock_bottleneck.md) details the shared socket lock contention resolved by utilizing MemcachedSR with `SO_REUSEPORT`.

The file [mutilate_tcp_only_limitation.md](file:///home/olly/UNI/NetCmp/BMC_Check/troubleshooting/mutilate_tcp_only_limitation.md) outlines the build system and protocol constraints we faced when compiling the `mutilate` workload generator and our decision to switch to `memaslap`.
