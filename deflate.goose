// Whole-buffer DEFLATE, zlib, and gzip through libdeflate. No streaming or
// automatic buffer growth. Handles are owned by convention: never copy a live
// handle, and close it explicitly. Use separate handles on concurrent threads.
namespace deflate;
import std;

// The compressed wire format; these are not interchangeable. Gzip operations
// process one member, not an entire concatenated file.
//
// ```goose
// let format = deflate::Format.Gzip;
// assert(format != deflate::Format.Raw);
// ```
enum Format { Raw, Zlib, Gzip }

// Decompression outcome. BadData reports invalid, truncated, or checksum-failing
// input. OutputTooSmall means decoding exceeded capacity; it does not establish
// input validity (a corrupt stream can hit this limit before corruption is
// detected). On either failure the output contents must be discarded.
//
// ```goose
// let d, ok = deflate::decompressor();
// assert(ok);
// defer d.close();
// var output: u8[16] = [0; 16];
// assert(d.decompress(deflate::Format.Gzip, "bad", output).status == deflate::Status.BadData);
// ```
enum Status { Success, BadData, OutputTooSmall, Closed }

// Counts describe the first stream/member on Success; both are zero on error.
// Trailing input is allowed: advance by consumed to process another member.
//
// ```goose
// let d = deflate::Decompressor { .. };
// var output: u8[1] = [0];
// let result = d.decompress(deflate::Format.Raw, "", output);
// assert(result.status == deflate::Status.Closed);
// assert(result.consumed == 0 && result.written == 0);
// ```
struct Result { consumed: i64, written: i64, status: Status }

// Reusable compressor. Default initialization is closed. The handle field is
// implementation detail: do not construct, copy, or modify a live handle.
//
// ```goose
// let c, ok = deflate::compressor(1);
// assert(ok);
// c.close();
// c.close();
// ```
struct Compressor { handle: u64 }

// Reusable decompressor for every supported format and compression level.
// Default initialization is closed. Do not copy or modify a live handle.
//
// ```goose
// let d, ok = deflate::decompressor();
// assert(ok);
// d.close();
// ```
struct Decompressor { handle: u64 }

extern fn open_compressor_raw(level: i32) -> u64 = "gdf_open_compressor";
extern fn open_decompressor_raw() -> u64 = "gdf_open_decompressor";
extern fn close_compressor_raw(handle: u64) = "gdf_close_compressor";
extern fn close_decompressor_raw(handle: u64) = "gdf_close_decompressor";
extern fn bound_raw(handle: u64, format: i32, size: i64) -> i64 = "gdf_bound";
extern fn compress_raw(handle: u64, format: i32, input: const u8[:], output: u8[:]) -> i64 = "gdf_compress";
extern fn decompress_raw(handle: u64, format: i32, input: const u8[:], output: u8[:], counts: i64[:]) -> i32 = "gdf_decompress";
extern fn crc32_raw(bytes: const u8[:], initial: u32) -> u32 = "gdf_crc32";
extern fn adler32_raw(bytes: const u8[:], initial: u32) -> u32 = "gdf_adler32";

inline fn format_code(format: Format) -> i32 {
    match format {
        Raw => 0,
        Zlib => 1,
        Gzip => 2,
    }
}

// Allocate once, then reuse across buffers and formats. Levels 0..12 are
// valid; -1 selects the upstream default (6). Returns a handle and success flag.
// Invalid levels and allocation failure return a closed handle and false.
//
// ```goose
// let c, ok = deflate::compressor(1);
// assert(ok);
// defer c.close();
// let invalid, accepted = deflate::compressor(13);
// assert(!accepted);
// invalid.close();
// ```
inline fn compressor(level: i32 = 6) -> Compressor, bool {
    let handle = open_compressor_raw(level);
    return Compressor { handle }, handle != 0;
}

// Allocate a reusable decompressor. Returns a closed handle and false on
// allocation failure. No allocations are made by subsequent decompress calls.
//
// ```goose
// let d, ok = deflate::decompressor();
// assert(ok);
// defer d.close();
// ```
inline fn decompressor() -> Decompressor, bool {
    let handle = open_decompressor_raw();
    return Decompressor { handle }, handle != 0;
}

// Free and invalidate a handle. Safe on closed or unsuccessfully opened handles.
//
// ```goose
// let c, ok = deflate::compressor();
// let d, ready = deflate::decompressor();
// assert(ok && ready);
// c.close();
// d.close();
// c.close();
// d.close();
// ```
inline fn close(c: Compressor&) {
    close_compressor_raw(c.handle);
    c.handle = 0;
}
// Free and invalidate a decompressor; safe to call more than once.
//
// ```goose
// let d, ok = deflate::decompressor();
// assert(ok);
// d.close();
// d.close();
// ```
inline fn close(d: Decompressor&) {
    close_decompressor_raw(d.handle);
    d.handle = 0;
}

// Worst-case compressed size for input_size bytes, or -1 for a closed handle,
// negative input size, or a bound not representable as i64. Allocate outside
// hot loops and reuse the buffer. The bound includes the selected wrapper.
//
// ```goose
// let c, ok = deflate::compressor(1);
// assert(ok);
// defer c.close();
// assert(c.bound(deflate::Format.Gzip, 65536) > 65536);
// assert(c.bound(deflate::Format.Raw, -1) == -1);
// ```
inline fn bound(c: const Compressor&, format: Format, input_size: i64) -> i64 {
    if c.handle == 0 { return -1; }
    return bound_raw(c.handle, format_code(format), input_size);
}

// Compress into caller-owned output without allocation or input copies.
// Returns bytes written, 0 if output is too small, or -1 for a closed handle.
// On failure discard output contents. Input/output must not overlap or change
// concurrently. Empty input still produces a nonempty compressed stream.
//
// ```goose
// let c, ok = deflate::compressor(1);
// assert(ok);
// defer c.close();
// var output: u8[128] = [0; 128];
// let size = c.compress(deflate::Format.Gzip, "hello hello", output);
// assert(size > 0 && size <= output.len);
// ```
inline fn compress(c: const Compressor&, format: Format, input: const u8[:], output: u8[:]) -> i64 {
    if c.handle == 0 { return -1; }
    return compress_raw(c.handle, format_code(format), input, output);
}

// Decode one stream/member into caller-owned output without allocation or input
// copies. Zlib/gzip checksums are verified; raw DEFLATE has no checksum.
// Input/output must not overlap or change concurrently. Output is a capacity,
// not an expected size: verify written yourself when an exact size is required.
// Trailing bytes are not an error. On failure discard output contents.
//
// ```goose
// let c, ok = deflate::compressor(1);
// let d, ready = deflate::decompressor();
// assert(ok && ready);
// defer c.close();
// defer d.close();
// var compressed: u8[128] = [0; 128];
// var output: u8[32] = [0; 32];
// let n = c.compress(deflate::Format.Gzip, "hello hello", compressed);
// assert(n > 0);
// let result = d.decompress(deflate::Format.Gzip, compressed[..n], output);
// assert(result.status == deflate::Status.Success);
// assert(result.consumed == n && result.written == 11);
// assert(output[..result.written] == "hello hello");
// ```
inline fn decompress(d: const Decompressor&, format: Format, input: const u8[:], output: u8[:]) -> Result {
    if d.handle == 0 { return Result { 0, 0, Status.Closed }; }
    var counts: i64[2] = [0; 2];
    let code = decompress_raw(d.handle, format_code(format), input, output, counts);
    var status = Status.BadData;
    if code == 0 { status = Status.Success; }
    if code == 3 { status = Status.OutputTooSmall; }
    return Result { counts[0], counts[1], status };
}

// CRC-32 (gzip/IEEE). Pass the previous checksum to extend it. Empty input
// preserves initial, including for a null-backed slice.
//
// ```goose
// assert(deflate::crc32("123456789") == 0xcbf43926);
// assert(deflate::crc32("56789", deflate::crc32("1234")) == 0xcbf43926);
// ```
inline fn crc32(bytes: const u8[:], initial: u32 = 0) -> u32 {
    return crc32_raw(bytes, initial);
}

// Adler-32 (zlib). Pass the previous checksum to extend it. Empty input preserves
// initial. This is an integrity checksum, not a cryptographic hash.
//
// ```goose
// assert(deflate::adler32("123456789") == 0x091e01de);
// assert(deflate::adler32("56789", deflate::adler32("1234")) == 0x091e01de);
// ```
inline fn adler32(bytes: const u8[:], initial: u32 = 1) -> u32 {
    return adler32_raw(bytes, initial);
}
