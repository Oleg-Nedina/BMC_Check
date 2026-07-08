# Baseline Orchestration Scripts

This directory contains the core orchestration scripts, client configurations, and setup procedures we used to replicate the baseline evaluations from the original BMC paper.

For infrastructure and deployment, we developed the [deploy_all.sh](file:///home/olly/UNI/NetCmp/BMC_Check/scripts/baseline/deploy_all.sh) script to automate SUT and client node initialization, compile our Memcached binaries, and distribute memaslap. We also wrote the [server_setup.sh](file:///home/olly/UNI/NetCmp/BMC_Check/scripts/baseline/server_setup.sh) script to prepare our remote network queues and mount the BPF filesystem.

Under closed-loop workloads, we run the [run_benchmark.sh](file:///home/olly/UNI/NetCmp/BMC_Check/scripts/baseline/run_benchmark.sh) orchestrator to execute memaslap throughput and latency tests, copying the helper [client_run.sh](file:///home/olly/UNI/NetCmp/BMC_Check/scripts/baseline/client_run.sh) to the clients and pulling our CSV datasets back.

Under open-loop workloads, we use the [run_trafgen_benchmark.sh](file:///home/olly/UNI/NetCmp/BMC_Check/scripts/baseline/run_trafgen_benchmark.sh) script to coordinate raw UDP floods from the clients, leveraging our configuration templates [trafgen_c1.cfg](file:///home/olly/UNI/NetCmp/BMC_Check/scripts/baseline/trafgen_c1.cfg), [trafgen_c2.cfg](file:///home/olly/UNI/NetCmp/BMC_Check/scripts/baseline/trafgen_c2.cfg), and the warm-up helper script [trafgen_warmup.py](file:///home/olly/UNI/NetCmp/BMC_Check/scripts/baseline/trafgen_warmup.py) to measure SUT scaling limits under saturating wire rates.
