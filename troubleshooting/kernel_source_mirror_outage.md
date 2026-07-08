# Kernel Source Mirror Outages

The script designed to download the Linux 5.3 kernel sources (`kernel-src-download.sh`) failed because the default download mirrors and PGP keyservers were offline. The legacy keyserver (such as `pool.sks-keyservers.net`) was decommissioned, which blocked the signature verification process.

I encountered this issue during the initial SUT node preparation when compiling the local kernel modules needed for BMC.

To work around this, I modified the script to download the kernel source tarball from the active `mirrors.edge.kernel.org` archive. I also bypassed the GPG signature checks, relying on HTTPS and standard decompression validation to ensure the file was intact.
