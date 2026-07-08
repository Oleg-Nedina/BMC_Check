# Memaslap Client Segmentation Faults

When attempting to run memaslap with high client concurrency (such as 512 connections per thread), the client process crashed immediately with a segmentation fault. This crash was caused by socket buffer allocation failures inside the memaslap utility when handling large numbers of concurrent UDP connections.

I encountered this issue during my multi-core closed-loop scaling tests.

To resolve this, I pinned the client concurrency to 128 per thread/socket. This provided a stable, saturating load to the SUT node without triggering memory faults on the clients.
