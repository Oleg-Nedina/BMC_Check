# Glibc Linker Symbol Contention

During the compilation of the Memcached codebase on the SUT node, the build failed at the linking stage due to multiple definitions of the global `hash` variable. This error occurs because modern Clang and GCC compilers on Ubuntu 22.04 default to `-fno-common`, which does not allow duplicate uninitialized global symbols.

I encountered this issue during the initial environment setup on CloudLab when first compiling the Memcached binaries.

To solve this, I configured the build with `CC=clang CFLAGS='-fcommon'` and removed the strict `-Werror` flag from the generated Makefiles. This forced the compiler to allow common block allocations, resolving the duplicate global symbols.
