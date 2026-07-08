# Flat Layer-2 Network Segment Assumption

This document details our analysis of the paper's network routing assumptions.

## Assumption Analyzed
The paper assumes that the database runs on a flat Layer-2 network segment. Under this assumption, returning a cached response is a simple matter of swapping the source and destination MAC and IP addresses of the incoming packet before transmitting it back.

## Our Critical Evaluation
We evaluated the limitations of this address-swap mechanism. If the database is deployed behind a router, a firewall, or inside a network segment utilizing Network Address Translation (NAT), this simple swap fails. Without looking up the correct gateway routing tables or modifying the packet headers according to NAT translation maps, the returned packet will be dropped by the network. We concluded that BMC requires a flat local network segment and cannot be deployed in routed multi-tenant environments without complex modifications.
