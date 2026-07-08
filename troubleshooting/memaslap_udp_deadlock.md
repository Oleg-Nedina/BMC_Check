# Memaslap UDP Event Loop Deadlocks

When running memaslap in UDP mode with a workload set to 100\% GET operations, the client event loop would lock up in a deadlock, failing to generate traffic. This deadlock happened because memaslap's internal UDP event handling loop relies on write events to trigger subsequent reads, causing sockets to block indefinitely without a write mix.

I encountered this issue during my first baseline closed-loop profiling runs on CloudLab.

To work around this, I adjusted the workload configuration to a 95\% GET and 5\% SET command ratio. The periodic write operations successfully kept the sockets active and prevented the client's internal event loop from freezing.
