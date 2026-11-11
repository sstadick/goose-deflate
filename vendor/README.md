# libdeflate

`libdeflate/` is the unmodified source archive of
[libdeflate v1.26](https://github.com/ebiggers/libdeflate/releases/tag/v1.26),
commit `92e6a0db9fa848d742f9eb286c92afc60f2c3dda`.
Its MIT license is in `libdeflate/COPYING`.

Vendoring makes package builds offline and independent of system library
versions. Build it with its own CMake project: that preserves architecture
selection and runtime CPU dispatch. No global `-march=native` or AVX2 requirement.
Updates should replace the source archive, then rerun interoperability tests
and the direct-C comparison benchmark. Do not patch the codec locally.
