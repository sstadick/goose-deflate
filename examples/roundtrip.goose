import std;
import deflate from "..";

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
