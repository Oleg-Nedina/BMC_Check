# Critical Assumptions Audit

This directory contains our critical evaluations and audits of the implicit architectural assumptions made by the authors in the original BMC paper. Each document details a specific assumption, when and why it is relevant, and our evaluation of its validity under real-world systems.

The file [write_distribution.md](file:///home/olly/UNI/NetCmp/BMC_Check/assumptions/write_distribution.md) covers our analysis of uniform write assumptions under skewed Zipfian workloads.

The file [flat_layer2_routing.md](file:///home/olly/UNI/NetCmp/BMC_Check/assumptions/flat_layer2_routing.md) details the address-swap limitations when operating under NAT or routed segments.

The file [driver_headroom_limits.md](file:///home/olly/UNI/NetCmp/BMC_Check/assumptions/driver_headroom_limits.md) explains Mellanox ConnectX-5 packet headroom drops during Multi-GET key expansions.

The file [time_to_live_expiration.md](file:///home/olly/UNI/NetCmp/BMC_Check/assumptions/time_to_live_expiration.md) details SUT temporal eviction limitations and stale cache reads.

The file [preallocated_kernel_memory.md](file:///home/olly/UNI/NetCmp/BMC_Check/assumptions/preallocated_kernel_memory.md) details the 4.29 GB physical memory allocation locked by the eBPF array map.
