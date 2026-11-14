import std;
import deflate from "..";

// The public API deliberately has no checkfree annotations. A checkfree caller
// must still verify the code it executes, including the fixed result counts.
checkfree fn roundtrip(format: deflate::Format, input: const u8[:]) {
    let c, ok = deflate::compressor(1);
    let d, ready = deflate::decompressor();
    assert(ok && ready);
    defer c.close();
    defer d.close();

    var compressed: u8[256] = [0; 256];
    var output: u8[64] = [0; 64];
    assert(c.bound(format, input.len) <= compressed.len);
    let n = c.compress(format, input, compressed);
    assert(n > 0 && n <= compressed.len);
    let result = d.decompress(format, compressed[..n], output);
    assert(result.status == deflate::Status.Success);
    assert(result.consumed == n && result.written == input.len);
    let written = result.written;
    assert(written >= 0 && written <= output.len);
    assert(output[..written] == input);
    assert(deflate::crc32(output[..written]) == deflate::crc32(input));
    assert(deflate::adler32(output[..written]) == deflate::adler32(input));

    // Explicit close, repeat-close via defer, and error counts remain intact.
    c.close();
    d.close();
    assert(c.bound(format, input.len) == -1);
    assert(c.compress(format, input, compressed) == -1);
    let closed = d.decompress(format, compressed, output);
    assert(closed.status == deflate::Status.Closed);
    assert(closed.consumed == 0 && closed.written == 0);
}

fn main() {
    for format in [deflate::Format.Raw, deflate::Format.Zlib, deflate::Format.Gzip] {
        roundtrip(format, "ACGTACGTACGT\n");
        roundtrip(format, "");
    }
}
