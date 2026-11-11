#!/usr/bin/env python3
"""Interoperate with Python/zlib on TinyCC and optimized native backends."""
import argparse
import gzip
import os
from pathlib import Path
import random
import subprocess
import tempfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
FORMATS = {"raw": -15, "zlib": 15, "gzip": 31}


def fixtures():
    rng = random.Random(7823)
    yield b"", 0
    yield b"\xff", -1
    yield b"123456789\x00\xff\r\n", 12
    for size in (31, 4096, 65535, 65536, 65537, 1048576):
        yield rng.randbytes(size), 1
        yield (b"ACGTN\x00\xffchr17\t12345\n" * (size // 18 + 1))[:size], 6
    # Every supported level, including stored blocks and the high-level parser.
    for level in range(13):
        yield rng.randbytes(101) * 41, level


def exercise(command, directory):
    for index, (data, level) in enumerate(fixtures()):
        (directory / "input").write_bytes(data)
        for name, wbits in FORMATS.items():
            strategy = (zlib.Z_DEFAULT_STRATEGY, zlib.Z_FIXED, zlib.Z_HUFFMAN_ONLY)[index % 3]
            encoder = zlib.compressobj(index % 10, zlib.DEFLATED, wbits, 8, strategy)
            encoded = encoder.compress(data) + encoder.flush()
            if name == "gzip" and index % 2:
                # Optional gzip name field, not just libdeflate's minimal header.
                with (directory / name).open("wb") as file:
                    with gzip.GzipFile(filename="reads.bam", mode="wb", fileobj=file, mtime=0) as stream:
                        stream.write(data)
            else:
                (directory / name).write_bytes(encoded)
        subprocess.run([*map(str, command), str(level)], cwd=directory, check=True)
        for name, wbits in FORMATS.items():
            decoder = zlib.decompressobj(wbits)
            encoded = (directory / f"{name}.out").read_bytes()
            assert decoder.decompress(encoded) + decoder.flush() == data, (index, name)
            assert decoder.eof and not decoder.unused_data, (index, name)
        actual = list(map(int, (directory / "checksums").read_text().split()))
        assert actual == [zlib.crc32(data), zlib.adler32(data)], index
    print(f"Passed {index + 1} fixtures × 3 formats: {' '.join(map(str, command))}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cc", nargs="+", default=["gcc", "clang"])
    args = parser.parse_args()
    goose = os.environ.get("GOOSE", "goose")
    source = ROOT / "tests/check.goose"
    with tempfile.TemporaryDirectory(prefix="goose-deflate-tests-") as temp:
        directory = Path(temp)
        for opt in (0, 2):
            exercise([goose, "run", source, "--debug", f"-O{opt}", "--"], directory)
        for cc in args.cc:
            exe = directory / ("check.exe" if os.name == "nt" else "check")
            # --debug makes native C unoptimized, regardless of Goose's -O2.
            # Exercise both checked/debug and the actual optimized fast path.
            for flags in (["--debug"], []):
                subprocess.run([goose, "build", str(source), *flags, "-O2", "--cc", cc,
                                "-o", str(exe)], cwd=ROOT, check=True)
                exercise([exe], directory)


if __name__ == "__main__":
    main()
