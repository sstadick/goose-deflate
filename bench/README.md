# Binding overhead versus direct C

On Linux x86-64, the Goose wrapper is near direct-C speed for block-sized
buffers. Both paths call the same libdeflate implementation; these measurements
are about the binding, not an advantage over libdeflate or a BAM throughput claim.

## Recorded run

2026-11-11, AMD Ryzen 9 3950X, Linux 6.8 / glibc 2.39, pinned to logical CPU 12.
Goose `74c641c5` (runtime `3025e5810379`), GCC 13.3.0, Clang 18.1.3,
libdeflate 1.26. Goose/native application C uses `-O2`; the shared codec build
uses CMake Release (`-O3 -DNDEBUG` on this host). No LTO or `-march=native`.
This is a shared development host, not an isolated benchmark machine; small
differences should not be interpreted as wins or regressions on their own.

**64 KiB synthetic read-like input, gzip, compression level 1:**

| Compiler | Operation | Goose MB/s | Goose time / direct C time |
| --- | --- | ---: | ---: |
| GCC | Compress | 279.7 | 0.997 |
| GCC | Decompress | 967.0 | 0.997 |
| Clang | Compress | 278.1 | 1.005 |
| Clang | Decompress | 990.3 | 0.996 |

MB/s uses uncompressed bytes and decimal megabytes. Ratio 1.00 means equal
time; values above 1.00 mean Goose took longer. These are medians of seven
samples, not the best sample.

The full sweep covers raw DEFLATE, zlib, gzip, CRC-32, and Adler-32 on read-like
and random bytes. Below, each row summarizes 16 case ratios (six codec cases
and two checksum cases, each with both input kinds):

| Compiler | Input bytes | Median ratio | Minimum–maximum ratio |
| --- | ---: | ---: | ---: |
| GCC | 64 | 1.005 | 0.957–1.049 |
| GCC | 4,096 | 0.997 | 0.963–1.046 |
| GCC | 65,536 | 1.000 | 0.952–1.025 |
| GCC | 1,048,576 | 1.000 | 0.999–1.004 |
| Clang | 64 | 1.003 | 0.994–1.054 |
| Clang | 4,096 | 1.001 | 0.997–1.031 |
| Clang | 65,536 | 1.000 | 0.995–1.006 |
| Clang | 1,048,576 | 1.000 | 0.993–1.003 |

The largest relative overhead was Clang CRC-32 on 64 random bytes:
6.655 ns in Goose versus 6.312 ns in direct C (**+0.343 ns, +5.4%**).
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
GCC/Clang command names or paths. Python 3.9+ and Goose are required. Use
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
goose build bench/bench.goose --cc clang -O2 -o /tmp/goose-deflate-bench
objdump -d /tmp/goose-deflate-bench | grep -E 'call.*<(gdf_|libdeflate_)'
```
