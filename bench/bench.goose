import std;
import os;
import deflate from "..";

extern fn direct_compress(handle: u64, format: i32, input: const u8[:], output: u8[:], iterations: i64) -> u64;
extern fn direct_decompress(handle: u64, format: i32, input: const u8[:], output: u8[:], iterations: i64) -> u64;
extern fn direct_checksum(operation: i32, input: const u8[:], iterations: i64) -> u64;

inline fn run(c: const deflate::Compressor&, d: const deflate::Decompressor&,
              format: deflate::Format, code: i32, operation: i32, direct: bool,
              input: const u8[:], compressed: u8[:], output: u8[:], iterations: i64) -> u64 {
    if direct {
        // Benchmark-only access to handles, to give C exactly the same state.
        if operation == 0 { return direct_compress(c.handle, code, input, compressed, iterations); }
        if operation == 1 { return direct_decompress(d.handle, code, compressed, output, iterations); }
        return direct_checksum(operation, input, iterations);
    }
    var sum: u64 = 0;
    if operation == 0 {
        for i in iterations {
            let n = c.compress(format, input, compressed);
            if n <= 0 { abort("compression failed"); }
            sum += n as u64;
        }
    } else if operation == 1 {
        for i in iterations {
            let r = d.decompress(format, compressed, output);
            if r.status != deflate::Status.Success || r.consumed != compressed.len || r.written != output.len {
                abort("decompression failed");
            }
            sum += (r.consumed + r.written) as u64;
        }
    } else if operation == 2 {
        for i in iterations { sum += deflate::crc32(input); }
    } else {
        for i in iterations { sum += deflate::adler32(input); }
    }
    return sum;
}

inline fn measure(format: deflate::Format, code: i32, operation: i32, direct: bool, iterations: i64) {
    var input: u8[>..] = [];
    if !read_file("input", input) || input.len == 0 { abort("missing input"); }
    let c, ok = deflate::compressor(1);
    let d, ready = deflate::decompressor();
    if !ok || !ready { abort("allocation failed"); }
    defer c.close();
    defer d.close();
    var compressed: u8[>..] = [];
    compressed.resize(c.bound(format, input.len), 0);
    var output: u8[>..] = [];
    output.resize(input.len, 0);
    let n = c.compress(format, input, compressed);
    if n <= 0 { abort("compression failed"); }
    let length = if operation == 0 { compressed.len } else { n };
    // Both paths are warmed; allocations, input reads and setup are not timed.
    let warm_goose = run(c, d, format, code, operation, false, input, compressed[..length], output, 8);
    let warm_c = run(c, d, format, code, operation, true, input, compressed[..length], output, 8);
    if warm_goose != warm_c { abort("warmup mismatch"); }
    let start = clock_ns();
    let sum = run(c, d, format, code, operation, direct, input, compressed[..length], output, iterations);
    let elapsed = clock_ns() - start;
    // Full byte verification outside the timed section, not just a checksum.
    let r = d.decompress(format, compressed[..n], output);
    if r.status != deflate::Status.Success || r.written != input.len || output != input {
        abort("incorrect output");
    }
    print(elapsed, " ", sum);
}

fn main() {
    let argv = args();
    if argv.len != 5 { abort("usage: bench c|goose format operation iterations"); }
    let format, f_ok = parse_int(argv[2]);
    let operation, o_ok = parse_int(argv[3]);
    let iterations, i_ok = parse_int(argv[4]);
    if !f_ok || !o_ok || !i_ok || iterations <= 0 { abort("bad arguments"); }
    if format == 0 {
        measure(deflate::Format.Raw, 0, operation as i32, argv[1] == "c", iterations);
    } else if format == 1 {
        measure(deflate::Format.Zlib, 1, operation as i32, argv[1] == "c", iterations);
    } else {
        measure(deflate::Format.Gzip, 2, operation as i32, argv[1] == "c", iterations);
    }
}
