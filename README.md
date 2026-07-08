# BMC Replication and Systems Analysis Project

This repository contains the complete delivery files for the Network Computing course project, focused on replicating and stress-testing Yoann Ghigoff's NSDI '21 paper "BMC: Accelerating Memcached using Safe In-Kernel Caching".

Rather than serving as a mere formal compliance container, this repository is designed to put all the practical scripts, configurations, and analytical tools developed and used throughout the project directly into the hands of the reader. This provides a transparent, functional, and hands-on overview of the system experiments, serving as a comprehensive complement to the final compiled [docs/REPORT_v3.1.pdf](file:///home/olly/UNI/NetCmp/BMC_Check/docs/REPORT_v3.1.pdf).

## Abstract

Kernel-space network processing has emerged as a vital technique to bypass standard Linux networking overheads (such as context switches, memory allocation, and socket lock contention) for high-performance key-value databases. BMC introduces a safe in-kernel cache running directly at the network interface card driver level using eBPF/XDP. This project replicates the paper's core claims, validating that driver-bypass achieves linear scaling under open-loop floods up to the physical network card limit. Furthermore, we expand the paper's scope by deploying seven custom stress testing scenarios to profile SUT behaviors under cold starts, tail latency requirements, non-target packet noise, Mellanox driver limitations, eBPF spinlock contention, RAPL package energy consumption, and write invalidation overheads. Our findings confirm that while driver-bypass provides massive speedups under saturating open-loop loads, the benefits vanish under closed-loop workloads where system throughput is strictly bounded by network propagation round-trip time.

## Directory Structure

The repository is structured into distinct top-level directories to isolate documentation, code, scripts, and debugging procedures.

The [docs/](file:///home/olly/UNI/NetCmp/BMC_Check/docs/) folder contains our core reference materials, including the original NSDI '21 paper, our final written report PDF, and the step-by-step setup configurations we executed on both SUT and client nodes.

The [bmc-cache_NC/](file:///home/olly/UNI/NetCmp/BMC_Check/bmc-cache_NC/) folder contains the accelerated BMC codebase fork, which has been patched to fix modern LLVM/Clang compiler unrolling bugs to pass the strict Linux kernel verifier checks.

The [scripts/](file:///home/olly/UNI/NetCmp/BMC_Check/scripts/) directory contains the custom automation and benchmarking programs, separated into a baseline folder for standard multi-core sweeps and an exploratory folder housing the seven custom closed-loop and open-loop stress testing programs.

The [troubleshooting/](file:///home/olly/UNI/NetCmp/BMC_Check/troubleshooting/) folder provides a detailed engineering log and reference guide detailing all the glibc linking errors, verifier rejects, memaslap event-loop deadlocks, and network card Toeplitz collisions we resolved.

The [assumptions/](file:///home/olly/UNI/NetCmp/BMC_Check/assumptions/) directory contains our critical engineering analysis of the five implicit assumptions made by the authors regarding write workloads, routing limitations, descriptor headroom, TTL expiration, and pre-allocated kernel memory.
