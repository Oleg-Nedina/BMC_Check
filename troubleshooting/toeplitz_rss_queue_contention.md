# Toeplitz RSS Queue Contention

During multi-core scaling tests (4 and 8 cores), SUT performance remained completely flat. System monitoring showed that only a single CPU core was running at 100% utilization processing network interrupts, while the remaining cores were idle. This happened because the network card's hardware Toeplitz hashing algorithm hashed the static IP/port flows of our client nodes to the same RX queue, directing all traffic to the same core.

I encountered this issue during my initial core scaling experiments (Target 1) when scaling the worker thread count.

To resolve this, I manually mapped the SUT RX queues and forced core affinities using the `ethtool` utility. This distributed the client traffic across all active cores and enabled multi-core scaling.
