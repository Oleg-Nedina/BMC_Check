# Specific Headroom Driver Support Assumption

This document details our analysis of the network card driver support assumptions.

## Assumption Analyzed
The paper assumes that network card drivers support native eBPF/XDP execution and provide enough descriptor headroom to expand incoming packets when generating multi-GET responses.

## Our Critical Evaluation
We tested this assumption by sweeping the number of aggregated keys in multi-GET requests. On our Mellanox ConnectX-5 interface, we discovered that recursive packet expansion using `bpf_xdp_adjust_head` is strictly limited. When we exceeded 10 aggregated keys, the driver's ring buffer headroom ran out of descriptors, causing the network card to silently drop the packets. This means that native driver acceleration is highly dependent on specific hardware capabilities and driver implementations, and cannot handle arbitrary multi-GET sizes without crashing or dropping packets.
