# Vanilla Memcached Socket Lock Bottleneck

When profiling Vanilla Memcached under open-loop flood at 8 cores, throughput collapsed to 128k TPS, performing significantly worse than at 4 cores (397k TPS). This collapse was caused by socket lock contention in the Linux kernel. Because Vanilla Memcached uses a single shared UDP socket, all worker threads contended simultaneously for the centralized socket lock (`sk->sk_lock`). Under high packet rates, this forced the CPU cores to serialize in the kernel's spinlock slowpath.

I encountered this issue during my multi-core open-loop validation runs under maximum network flood.

To resolve this, I used MemcachedSR, which implements the `SO_REUSEPORT` socket option. This assigns an independent UDP socket for each worker thread, allowing the network card to route packets directly to the correct core queue and avoiding lock contention.
