# Clang Loop Unrolling and Verifier Rejection

When loading the compiled BMC eBPF program, the kernel verifier rejected the bytecode and threw an `invalid access to packet` error. This rejection was caused by the modern Clang compiler (version 14 or higher) performing aggressive loop optimizations and unrolling the whitespace-skipping loop in `bmc_kern.c`. The optimization reordered packet boundary checks, confusing the verifier's static bounds analysis.

I encountered this issue during the SUT setup when trying to load the XDP program on the SUT network interface for the first time.

To resolve this, I refactored the loop in [bmc_kern.c](file:///home/olly/UNI/NetCmp/BMC_Check/bmc-cache_NC/bmc/bmc_kern.c) to load a fresh `data_end` pointer (`ws_data_end`) specifically for the whitespace checks. This forced the compiler to maintain the boundary checks in each iteration, satisfying the verifier and allowing the program to load.
