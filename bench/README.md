# Binding overhead versus direct C

On Linux x86-64, the Goose wrapper is near direct-C speed for block-sized
buffers. Both paths call the same libdeflate implementation; these measurements
are about the binding, not an advantage over libdeflate or a BAM throughput claim.

## Recorded run

2026-11-11, AMD Ryzen 9 3950X, Linux 6.8 / glibc 2.39, pinned to logical CPU 12.
Goose `74c641c5` (runtime `3025e5810379`), GCC 13.3.0, Clang 18.1.3,
libdeflate 1.26. Generated application C, the runtime, and the direct-C baseline
use native `-O3`; the shared codec uses `-O3 -DNDEBUG`. Goose frontend inlining
uses `-O2`, which is unrelated to native optimization. The runner emits standalone
C and compiles it directly because `goose build` hard-codes native `-O2`.
No LTO or `-march=native`.
This is a shared development host, not an isolated benchmark machine; small
differences should not be interpreted as wins or regressions on their own.

**64 KiB synthetic read-like input, gzip, compression level 1:**

| Compiler | Operation | Goose MB/s | Goose time / direct C time |
| --- | --- | ---: | ---: |
| GCC | Compress | 281.5 | 1.001 |
| GCC | Decompress | 992.0 | 0.995 |
| Clang | Compress | 281.5 | 0.999 |
| Clang | Decompress | 988.7 | 1.000 |

MB/s uses uncompressed bytes and decimal megabytes. Ratio 1.00 means equal
time; values above 1.00 mean Goose took longer. These are medians of seven
samples, not the best sample.

The full sweep covers raw DEFLATE, zlib, gzip, CRC-32, and Adler-32 on read-like
and random bytes. Below, each row summarizes 16 case ratios (six codec cases
and two checksum cases, each with both input kinds):

| Compiler | Input bytes | Median ratio | Minimum–maximum ratio |
| --- | ---: | ---: | ---: |
| GCC | 64 | 1.002 | 0.988–1.081 |
| GCC | 4,096 | 1.000 | 0.979–1.050 |
| GCC | 65,536 | 1.000 | 0.995–1.004 |
| GCC | 1,048,576 | 1.000 | 0.994–1.004 |
| Clang | 64 | 1.002 | 1.000–1.047 |
| Clang | 4,096 | 1.000 | 0.996–1.015 |
| Clang | 65,536 | 1.000 | 0.989–1.002 |
| Clang | 1,048,576 | 0.999 | 0.973–1.020 |

The largest relative overhead was GCC CRC-32 on 64 read-like bytes:
6.337 ns in Goose versus 5.864 ns in direct C (**+0.473 ns, +8.1%**).
The API's closed-handle/empty-input checks and returned counts are not free
for extremely short calls. They do not introduce a second out-of-line native
adapter call: inspecting both optimized binaries found direct libdeflate calls
and **no calls to `gdf_*` adapters**.

Random input often becomes stored DEFLATE blocks, so decoding it mostly measures
copying. Its very high throughput must not be read as general decompression
throughput. The read-like data includes names, bases, and qualities but is
synthetic, not a SAM/BAM corpus. Only compression level 1 is timed; correctness
tests cover all levels. No TinyCC, ARM, macOS, Windows, streaming, or parallel
performance claim is made.

## Reproduce

From the package root, run timings serially on an otherwise idle host:

```sh
taskset -c 12 python3 bench/run.py --cc gcc clang --output bench/results.json
```

Choose an available CPU; omit `taskset` where unavailable. The runner supports
GCC/Clang command names or paths. Python 3.9+, CMake, and Goose are required. Use
`--rounds`, `--seconds`, or `--sizes` for a shorter exploratory run; defaults
are seven rounds, approximately 50 ms per sample, and the four sizes above.
`GOOSE` selects the compiler. Raw samples, versions, iteration counts, and
affinity from the recorded run are in [results.json](results.json).

## What the comparison holds constant

- One executable per compiler contains both the Goose loop and the
  [direct C loop](direct.h). Both link the same static libdeflate archive;
  there is no system-library baseline with different build flags.
- Handles and input/output buffers are allocated before timing and reused.
  File I/O, compression of the decompression fixture, and allocation are excluded.
- Each process warms both paths, then times one selected path. Paired processes
  alternate Goose-first and C-first order across rounds. Iteration counts are
  calibrated from the direct C path and are identical within a pair.
- Both timed loops check compression success or decompression status and exact
  byte counts. Accumulated results must agree. Full decoded bytes are checked
  after timing. Checksum operations accumulate every returned checksum.
- Each input is deterministic. No expected timing or ratio is hard-coded, and
  the benchmark has no flaky CI performance threshold.

Inspect the native boundary on Linux with:

```sh
work=$(mktemp -d)
goose -o "$work/bench.c" --standalone -O2 bench/bench.goose
cmake -S vendor/libdeflate -B "$work/codec" -DCMAKE_C_COMPILER=clang \
  -DCMAKE_BUILD_TYPE=Release '-DCMAKE_C_FLAGS_RELEASE=-O3 -DNDEBUG' \
  -DLIBDEFLATE_BUILD_SHARED_LIB=OFF -DLIBDEFLATE_BUILD_GZIP=OFF
cmake --build "$work/codec" --target libdeflate_static
clang -O3 "$work/bench.c" "$work/codec/libdeflate.a" -lm -pthread -ldl -o "$work/bench"
objdump -d "$work/bench" | grep -E 'call.*<(gdf_|libdeflate_)'
rm -rf "$work"
```
