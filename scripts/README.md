# Benchmark and Stress Scripts

This directory contains the automation, orchestration, and plotting scripts we developed to evaluate our system under test. We organized the folder into subdirectories to separate our baseline replication campaigns from our custom exploratory stress testing campaigns.

The baseline subdirectory contains the orchestration scripts we used to reproduce the main multi-core scaling, memory sweep, and worst-case overhead results described in the original paper.

The exploratory subdirectory houses the stress-testing scripts we designed to isolate our SUT performance limits, warm-up characteristics, packet losses, lock serialization, and energy efficiency.

We placed our main plotting script [generate_all_plots.py](file:///home/olly/UNI/NetCmp/BMC_Check/scripts/generate_all_plots.py) in this root folder to parse our local CSV metrics and output conformed academic bar charts to verify our results.
