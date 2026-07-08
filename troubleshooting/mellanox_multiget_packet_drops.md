# Mellanox ConnectX-5 Multi-GET Packet Drops

During Multi-GET tests, requests containing 10 or more keys were dropped silently, causing client socket timeouts. SUT network statistics showed that packets physically arrived at the NIC but never reached the userspace application. This occurred because BMC processes multi-GETs by recursively calling `bpf_xdp_adjust_head` to shift the packet offset. On our Mellanox ConnectX-5 NIC, performing more than 10 headroom adjustments on the same descriptor violated the driver's ring buffer limits, causing the driver to discard the packet.

I encountered this issue during my exploratory Multi-GET key limit sweep (CC4).

To diagnose this, I ran the Cilium `pwru` (packet where are you) kprobe tracer on the SUT node. The traces confirmed that the packets were dropped early inside the Mellanox driver's receive ring. The workaround for this hardware limitation is to forward multi-GET requests containing more than 10 keys directly to userspace (via `XDP_PASS`), or limit key aggregation on the client.
