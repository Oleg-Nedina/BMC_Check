# Infinite Key Time-To-Live Assumption

This document details our analysis of the paper's assumptions regarding database key expiration.

## Assumption Analyzed
The paper assumes that keys stored in the database do not have active Time-To-Live (TTL) limits, or that cache consistency is handled without temporal evictions.

## Our Critical Evaluation
In production environments, many Memcached keys are configured with a TTL to expire automatically (such as session tokens or security codes). We analyzed the eBPF codebase and found that BMC has no built-in temporal eviction or aging mechanism. When a key expires in userspace Memcached, the eBPF cache is unaware of the expiration. It will continue to serve the stale value directly from the kernel to the client until a new SET operation manually overwrites the slot. This is a severe correctness violation that we documented as a major limitation of stateless in-kernel caching.
