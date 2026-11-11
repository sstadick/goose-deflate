import std;
import os;
import deflate from "..";

fn check(format: deflate::Format, name: const u8[:], level: i32) {
    var input: u8[>..] = [];
    var encoded: u8[>..] = [];
    assert(read_file("input", input));
    assert(read_file(name, encoded));
    let c, ok = deflate::compressor(level);
    let d, ready = deflate::decompressor();
    assert(ok && ready);
    defer c.close();
    defer d.close();

    // Offset slices exercise unaligned input/output; guard bytes detect overruns.
    var output: u8[>..] = [];
    output.resize(input.len + 3, 0xa5);
    var shifted: u8[>..] = [0xff];
    shifted.append(encoded);
    let result = d.decompress(format, shifted[1..], output[1..input.len + 1]);
    assert(result.status == deflate::Status.Success);
    assert(result.consumed == encoded.len && result.written == input.len);
    assert(output[1..input.len + 1] == input);
    assert(output[0] == 0xa5 && output[input.len + 1] == 0xa5 && output[input.len + 2] == 0xa5);

    // A capacity larger than the decoded size is valid, not ShortOutput.
    let larger = d.decompress(format, encoded, output);
    assert(larger.status == deflate::Status.Success && larger.written == input.len);
    if input.len > 0 {
        let small = d.decompress(format, encoded, output[..input.len - 1]);
        assert(small.status == deflate::Status.OutputTooSmall);
        assert(small.consumed == 0 && small.written == 0);
    }
    let truncated = d.decompress(format, encoded[..encoded.len - 1], output);
    // A malformed stream may exhaust output before the codec detects truncation.
    assert(truncated.status == deflate::Status.BadData || truncated.status == deflate::Status.OutputTooSmall);
    assert(truncated.consumed == 0 && truncated.written == 0);

    // The API stops at exactly one stream/member, even with another following.
    var joined: u8[>..] = [];
    joined.append(encoded);
    joined.append(encoded);
    joined.append("trailing garbage");
    let first = d.decompress(format, joined, output);
    assert(first.status == deflate::Status.Success && first.consumed == encoded.len);
    let second = d.decompress(format, joined[first.consumed..], output);
    assert(second.status == deflate::Status.Success && second.consumed == encoded.len);
    assert(output[..second.written] == input);

    var compressed: u8[>..] = [];
    let bound = c.bound(format, input.len);
    assert(bound >= input.len && bound > 0);
    compressed.resize(bound + 2, 0x5a);
    let n = c.compress(format, input, compressed[1..bound + 1]);
    assert(n > 0 && n <= bound);
    assert(compressed[0] == 0x5a && compressed[bound + 1] == 0x5a);
    // Python independently decodes these bytes, not a second copy of this codec.
    assert(write_file(str(name, ".out"), compressed[1..n + 1]));
    let own = d.decompress(format, compressed[1..n + 1], output);
    assert(own.status == deflate::Status.Success && own.written == input.len);
    assert(output[..own.written] == input);
    assert(c.compress(format, input, compressed[..0]) == 0);
    assert(c.bound(format, -1) == -1);
    assert(c.bound(format, 0x7fffffffffffffff) == -1);

    if format != deflate::Format.Raw {
        // Corrupt only the stored checksum, not the DEFLATE payload.
        let offset = if format == deflate::Format.Gzip { encoded.len - 8 } else { encoded.len - 4 };
        encoded[offset] ^= 1;
        let corrupt = d.decompress(format, encoded, output);
        assert(corrupt.status == deflate::Status.BadData);
        assert(corrupt.consumed == 0 && corrupt.written == 0);
    }
    // Handles remain reusable after errors, then explicitly become closed.
    assert(d.decompress(format, compressed[1..n + 1], output).status == deflate::Status.Success);
    c.close();
    d.close();
    assert(c.compress(format, input, output) == -1);
    assert(c.bound(format, input.len) == -1);
    assert(d.decompress(format, encoded, output).status == deflate::Status.Closed);
}

fn main() {
    let argv = args();
    assert(argv.len == 2);
    let level, valid = parse_int(argv[1]);
    assert(valid);
    check(deflate::Format.Raw, "raw", level as i32);
    check(deflate::Format.Zlib, "zlib", level as i32);
    check(deflate::Format.Gzip, "gzip", level as i32);

    var empty: u8[>..] = [];
    assert(deflate::crc32("123456789") == 0xcbf43926);
    assert(deflate::adler32("123456789") == 0x091e01de);
    assert(deflate::crc32("56789", deflate::crc32("1234")) == 0xcbf43926);
    assert(deflate::adler32("56789", deflate::adler32("1234")) == 0x091e01de);
    assert(deflate::crc32(empty, 0xcbf43926) == 0xcbf43926);
    assert(deflate::adler32(empty, 0x091e01de) == 0x091e01de);
    assert(deflate::crc32(empty) == 0 && deflate::adler32(empty) == 1);
    for invalid in [-2, 13] {
        let c, ok = deflate::compressor(invalid as i32);
        assert(!ok);
        c.close();
    }
    let c = deflate::Compressor { .. };
    let d = deflate::Decompressor { .. };
    assert(c.compress(deflate::Format.Raw, empty, empty) == -1);
    assert(d.decompress(deflate::Format.Raw, empty, empty).status == deflate::Status.Closed);
    c.close();
    d.close();
    var input: u8[>..] = [];
    assert(read_file("input", input));
    assert(write_file("checksums", str(deflate::crc32(input), " ", deflate::adler32(input))));
}
