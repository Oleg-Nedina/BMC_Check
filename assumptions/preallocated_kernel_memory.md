# Pre-Allocated Kernel Memory Assumption

This document details our analysis of the paper's assumptions regarding kernel memory efficiency.

## Assumption Analyzed
The paper describes BMC as a lightweight, non-intrusive cache that does not require kernel modifications or cause significant system memory pressure.

## Our Critical Evaluation
We audited the eBPF map configuration in the source code and found that the main cache map (`map_kcache`) is pre-allocated as a static array containing $2^{27}$ entries. Because eBPF arrays must be fully pre-allocated at load time to prevent memory allocation faults in interrupt context, the SUT kernel statically locks approximately 4.29 GB of non-swappable physical RAM. This memory remains locked even if the database is completely empty. We highlighted this as a significant hidden cost that can impact collocated virtual machines or applications sharing the same physical host.
