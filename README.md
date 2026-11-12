# goose-deflate

Whole-buffer DEFLATE, zlib, and gzip for [Goose](https://github.com/aardappel/goose),
backed by [libdeflate](https://github.com/ebiggers/libdeflate). Reuse compressor
and decompressor handles and supply your own buffers: compression and
decompression make no per-call allocations or input copies.

**[API reference and executable examples](API.md)** · [Performance](bench/README.md)

## Get started

From this checkout, run the [complete example](examples/roundtrip.goose):

```sh
goose run examples/roundtrip.goose
goose build examples/roundtrip.goose --cc clang -O2 -o roundtrip
./roundtrip
```

The local example imports `deflate from ".."` because it lives in `examples/`.
For another application, save this complete program as `main.goose`; Goose
fetches the package from GitHub. No other Goose packages are required.
The example follows `main`; use a published tag from
[Releases](https://github.com/sstadick/goose-deflate/releases) or a full commit SHA
for a reproducible dependency.

```goose
import std;
import deflate from "github.com/sstadick/goose-deflate@main";

fn main() {
    let c, ok = deflate::compressor(1);
    let d, ready = deflate::decompressor();
    assert(ok && ready);
    defer c.close();
    defer d.close();

    let input = "ACGTACGTACGT\n";
    var compressed: u8[>..] = [];
    compressed.resize(c.bound(deflate::Format.Gzip, input.len), 0);
    let n = c.compress(deflate::Format.Gzip, input, compressed);
    assert(n > 0);

    var output: u8[64] = [0; 64];
    let result = d.decompress(deflate::Format.Gzip, compressed[..n], output);
    assert(result.status == deflate::Status.Success);
    assert(result.consumed == n && result.written == input.len);
    assert(output[..result.written] == input);
}
```

Requires Goose with package `c_headers` and CMake support, CMake 3.20+, and a
native C compiler. Development and CI pin Goose
[`d5ae5bbd`](https://github.com/aardappel/goose/commit/d5ae5bbda990923fa4129f969c7f853c20d4d1e6)
(`v2026.4-20-gd5ae5bbd`, runtime `d521138194f1`). The original
[`74c641c5`](https://github.com/aardappel/goose/commit/74c641c5ac6d762e57e3177678fe9dea414d042a)
baseline also passes the Linux x86-64 checks; the recorded benchmarks retain
that compiler and their original measurements.
Even `goose run` needs a native compiler for libdeflate; TinyCC compiles the
Goose program, not the codec. The package builds its vendored libdeflate 1.26
through Goose's native build cache. No system libdeflate, Rust toolchain,
submodule checkout, or build-time download is needed.

## Buffer and error contracts

| Operation | Result |
| --- | --- |
| `compressor(level = 6)` | Compressor and success flag; levels -1 through 12 (-1 means 6). |
| `decompressor()` | Decompressor and success flag. |
| `c.bound(format, input_size)` | Worst-case output size, or -1 for invalid size, overflow, or a closed handle. |
| `c.compress(format, input, output)` | Positive byte count; 0 if output is too small; -1 if closed. |
| `d.decompress(format, input, output)` | `Result { consumed, written, status }`. |
| `crc32(bytes, initial = 0)` | IEEE CRC-32, optionally extending a previous checksum. |
| `adler32(bytes, initial = 1)` | Adler-32, optionally extending a previous checksum. |
| `handle.close()` | Frees and invalidates a handle; safe to repeat. |

- `Format.Raw`, `Format.Zlib`, and `Format.Gzip` select the wire format.
- Decompression stops after **one stream/member**. Trailing bytes are allowed;
  advance by `consumed` to process concatenated gzip members. Both counts are
  zero on error. `written` may be smaller than the output capacity.
- `Status.Success`, `BadData`, `OutputTooSmall`, and `Closed` distinguish outcomes.
  Malformed input can exhaust the output buffer before corruption is detected:
  `OutputTooSmall` is not a validity check. Discard output contents on failure.
- Gzip and zlib verify their checksums. Raw DEFLATE has no integrity checksum.
  If a surrounding format supplies a size or CRC, validate those separately.
- Input and output must not overlap. Do not modify buffers concurrently.
- Handles are owned by convention, not enforced by the type system. Do not copy
  or forge handles. Close each allocation, preferably with `defer`. Default
  initialized handles are closed. Each concurrent worker needs its own handles.

This is **not streaming gzip**. Callers need the complete compressed member and
sufficient output capacity. It fits bounded independent blocks such as BGZF;
it does not yet provide BGZF framing, virtual offsets, file I/O, or threading.
Do not allocate based on an untrusted gzip trailer without enforcing a limit.

## Why the native boundary stays small

Like goose-simd, `deflate.build` injects a `c_headers` adapter into generated C
after Goose's type definitions. Native GCC/Clang/MSVC can inline slice unpacking
and format selection into the caller, leaving a direct libdeflate call.
The codec remains a separately compiled static library with upstream runtime
CPU dispatch; no global AVX2 or `-march=native` requirement is imposed.

TinyCC calls exported native adapters compiled from the same header. It still
uses the optimized libdeflate implementation, not a scalar codec replacement.
The adapters use Goose's packed slice ABI and copy only two result counts, not
the buffers. The compiler pin matters: the generated C ABI is not a stable ABI.

Keep handles and buffers outside hot loops. Bounds calculation and buffer
allocation belong in setup. See the [matched direct-C benchmark](bench/README.md)
for measured binding overhead, including short inputs.

## Development

```sh
python3 tests/run.py --cc gcc clang
scripts/docs.sh
scripts/docs.sh --check
scripts/doctest.sh
scripts/doctest.sh --cc gcc
scripts/doctest.sh --cc clang
```

`GOOSE` selects the compiler; `GOOSE_DOC` names goose-doc's `main.goose`, defaulting
to `../goose-doc/main.goose`. API comments are the documentation source;
`api.txt` selects the public API. The scripts generate `API.md` and execute every
example with assertions. CI pins goose-doc v0.3.1's commit.

Tests decode independent Python/zlib fixtures and have Python decode Goose's
output. They cover all formats and compression levels, random and repetitive
bytes, empty input, 64 KiB boundaries, unaligned slices, undersized buffers,
checksums, truncation, optional gzip filenames, concatenated members, and handle
reuse/close. TinyCC runs with Goose optimization off/on; native compilers run
both debug and optimized builds. Goose assertions remain active in both.

CI is configured for Linux x86-64/ARM64, macOS ARM64, and Windows x86-64, with
GCC/Clang, Clang, and MSVC/clang-cl respectively. Only Linux x86-64 has been
verified locally; the other platforms require their native CI runs. Version
tags publish a source release and commit-linked API reference only after that
matrix passes. Published versions and their API references are listed in
[Releases](https://github.com/sstadick/goose-deflate/releases).

## License

MIT; see [LICENSE](LICENSE). Vendored libdeflate is also MIT, with its own
[copyright notice](vendor/libdeflate/COPYING) and [pinned provenance](vendor/README.md).
