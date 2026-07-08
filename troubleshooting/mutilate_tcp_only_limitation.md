# Mutilate Load Generator Limitations

This document details the issues and limitations we faced when trying to deploy the `mutilate` workload generator as our benchmark client.

## Problem Description
To measure SUT behavior under custom Zipfian distributions, we initially planned to use `mutilate` because it allows fine-grained control over the Zipf alpha parameter. However, we ran into compile and design issues. First, the build system of `mutilate` (`SConstruct`) is written in legacy Python 2, which triggered syntax errors under our modern Python 3 environments. Second, because our CloudLab client nodes run on an isolated network without internet access, installing missing build dependencies on the fly was highly complex. Most importantly, after patching the build script and successfully compiling the binary, we discovered that `mutilate` only supports TCP connections. Because the BMC in-kernel cache only accelerates UDP Memcached traffic, using a TCP-only generator made it impossible to trigger the XDP bypass code path.

## When It Was Encountered
We encountered these compilation and protocol constraints during the early test planning phase, when we were choosing the workload generators for our closed-loop experiments.

## Solution and Workaround
We resolved the build issues by patching the `SConstruct` file to update the print syntax for Python 3 compatibility. However, to work around the TCP protocol limitation, we decided to drop `mutilate` and use `memaslap` for our closed-loop campaigns. Since `memaslap` natively supports UDP and allows configuring key access distributions, we were able to successfully trigger BMC acceleration and collect our baseline and stress metrics.
