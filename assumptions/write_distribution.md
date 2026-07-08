# Uniform Write Distribution Assumption

This document details our analysis of the paper's assumption regarding write operation patterns.

## Assumption Analyzed
The paper assumes that write operations (SET commands) are uniformly distributed across the key space and do not disproportionately target hot keys. Under this assumption, invalidating cache slots in the eBPF map is lightweight because it rarely affects the most frequently accessed keys.

## Our Critical Evaluation
In production systems, key-value workloads are highly skewed, and write commands often target hot keys (such as session counters or rate limiters). When we tested this scenario, we observed that repeatedly writing to hot keys triggers constant cache evictions. This forces SUT threads to continuously push updates from userspace to the kernel, generating a high synchronization tax that collapses throughput. We concluded that the uniform write assumption does not hold for real-world dynamic databases.
