# CloudLab Client Node Setup Configuration

This document lists the correct sequence of setup and compilation commands we executed on the Client nodes to prepare the workload generator (`memaslap`).

Important Network Constraint: CloudLab client nodes cannot reach GitHub or external repositories directly. Only the SUT node has outbound internet access via the control network. Therefore, we compile `memaslap` on the SUT and then copy the binary to both clients via `scp` over the experiment network (`10.10.1.x`).

## System Dependencies on Clients
We install the runtime libraries needed to execute the `memaslap` binary.

For the local command version, we run the following commands on both client nodes:
```bash
ssh client1 "sudo apt update && sudo apt install -y build-essential libevent-dev libsasl2-dev cmake"
ssh client2 "sudo apt update && sudo apt install -y build-essential libevent-dev libsasl2-dev cmake"
```

## Build memaslap on the SUT
Since the clients cannot reach GitHub, we clone, patch, and build `libmemcached-awesome` on the SUT node, which has control-network internet access, and then copy the resulting binary.

For the local clone command, we run:
```bash
ssh sut "cd ~ && git clone --depth=1 https://github.com/awesomized/libmemcached.git libmemcached-awesome"
```
For the local patch command, which suppresses stdout verbosity prints to prevent SSH buffer saturation during mixed workloads, we run:
```bash
ssh sut "sed -i '496s/printf/\/\/ printf/' ~/libmemcached-awesome/contrib/bin/memaslap/ms_task.c"
```
For the local compilation command, we execute:
```bash
ssh sut "cd ~/libmemcached-awesome && mkdir -p build && cd build && cmake -DENABLE_MEMASLAP=ON .. && make -j4 2>&1 | tail -5"
```
The compiled binary is written to `~/libmemcached-awesome/build/src/bin/memaslap`.

## Copy memaslap Binary to Both Clients
We transfer the compiled binary from SUT to both clients over the experiment network.

For the local command version, we execute:
```bash
# From SUT, copy to both clients
ssh sut "scp ~/libmemcached-awesome/build/src/bin/memaslap 10.10.1.2:~/memaslap"
ssh sut "scp ~/libmemcached-awesome/build/src/bin/memaslap 10.10.1.3:~/memaslap"
```
We verify the experiment IPs of client1 and client2 with `ssh client1 "ip addr show | grep 'inet 10\.'"` before copying.

## Verify memaslap on Clients
We run version checks to verify that the binary is executable on the client nodes:
```bash
ssh client1 "~/memaslap --version"
ssh client2 "~/memaslap --version"
```

## Connectivity Check
We test the experiment network path from each client to the SUT node:
```bash
ssh client1 "ping -c 3 10.10.1.1"
ssh client2 "ping -c 3 10.10.1.1"
```
