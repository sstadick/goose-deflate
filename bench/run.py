#!/usr/bin/env python3
"""Measure Goose binding overhead against direct C calls in the same executable."""
import argparse
import json
import os
from pathlib import Path
import platform
import random
import shutil
import statistics
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def dataset(size, kind):
    rng = random.Random(173)
    if kind == "random":
        return rng.randbytes(size)
    # Synthetic read-like bytes, not a BAM file or a biological benchmark.
    data = bytearray()
    while len(data) < size:
        data.extend(f"read:{len(data)}\x00chr17\t".encode())
        data.extend(rng.choices(b"ACGT", k=150))
        data.extend(rng.choices(b"IIIIIIIIIIIIII!5?", k=150))
    return bytes(data[:size])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cc", nargs="+", default=["gcc", "clang"])
    parser.add_argument("--rounds", type=int, default=7)
    parser.add_argument("--seconds", type=float, default=0.05, help="target time per sample")
    parser.add_argument("--sizes", type=int, nargs="+", default=[64, 4096, 65536, 1048576])
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.rounds < 1 or args.seconds <= 0 or any(size <= 0 for size in args.sizes):
        parser.error("rounds, seconds, and sizes must be positive")
    goose = os.environ.get("GOOSE", "goose")
    report = {"platform": platform.platform(), "processor": platform.processor(),
              "goose": subprocess.check_output([goose, "--version"], text=True).strip(),
              "affinity": sorted(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else None,
              "goose_inlining": "-O2", "native_flags": ["-O3"],
              "codec_flags": ["-O3", "-DNDEBUG"],
              "rounds": args.rounds, "seconds": args.seconds, "results": []}
    with tempfile.TemporaryDirectory(prefix="goose-deflate-bench-") as temp:
        directory = Path(temp)
        source = directory / "bench.c"
        # Goose's -O2 controls inlining; goose build hard-codes native -O2.
        # Emit the runtime with the program so every timed C path uses -O3.
        subprocess.run([goose, "-o", str(source), "--standalone", "-O2",
                        str(ROOT / "bench/bench.goose")], cwd=ROOT, check=True)
        for index, cc in enumerate(args.cc):
            exe = directory / ("bench.exe" if os.name == "nt" else "bench")
            build = directory / f"codec-{index}"
            subprocess.run(["cmake", "-S", str(ROOT / "vendor/libdeflate"), "-B", str(build),
                            "-DCMAKE_BUILD_TYPE=Release", f"-DCMAKE_C_COMPILER={shutil.which(cc) or cc}",
                            "-DCMAKE_C_FLAGS_RELEASE=-O3 -DNDEBUG", "-DLIBDEFLATE_BUILD_SHARED_LIB=OFF",
                            "-DLIBDEFLATE_BUILD_GZIP=OFF", "-DLIBDEFLATE_BUILD_TESTS=OFF"], check=True)
            subprocess.run(["cmake", "--build", str(build), "--config", "Release",
                            "--target", "libdeflate_static", "--verbose"], check=True)
            archive, = build.rglob("libdeflate.a")
            libraries = [] if os.name == "nt" else ["-lm", "-pthread"]
            if platform.system() == "Linux":
                libraries.append("-ldl")
            command = [cc, "-O3", str(source), str(archive), "-o", str(exe), *libraries]
            print("Native build:", command, flush=True)
            subprocess.run(command, check=True)
            compiler = subprocess.check_output([cc, "--version"], text=True).splitlines()[0]

            def sample(mode, fmt, operation, iterations):
                text = subprocess.check_output([str(exe), mode, str(fmt), str(operation), str(iterations)],
                                               cwd=directory, text=True)
                ns, checksum = map(int, text.split())
                return ns, checksum

            for size in args.sizes:
                for kind in ("reads", "random"):
                    (directory / "input").write_bytes(dataset(size, kind))
                    for fmt, format_name in enumerate(("raw", "zlib", "gzip")):
                        operations = ("compress", "decompress", "crc32", "adler32") if fmt == 0 else ("compress", "decompress")
                        for operation, name in enumerate(operations):
                            probe, _ = sample("c", fmt, operation, 100)
                            iterations = max(10, min(10000000, int(args.seconds * 1e9 * 100 / max(1, probe))))
                            times = {"goose": [], "c": []}
                            for round_ in range(args.rounds):
                                checksums = []
                                for mode in (("goose", "c") if round_ % 2 == 0 else ("c", "goose")):
                                    ns, checksum = sample(mode, fmt, operation, iterations)
                                    times[mode].append(ns / iterations)
                                    checksums.append(checksum)
                                assert checksums[0] == checksums[1], (cc, size, kind, name)
                            g, c = (statistics.median(times[mode]) for mode in ("goose", "c"))
                            row = {"compiler": compiler, "cc": cc, "size": size, "kind": kind,
                                   "format": format_name, "operation": name, "iterations": iterations,
                                   "goose_ns": g, "c_ns": c, "ratio": g / c, "samples_ns": times}
                            report["results"].append(row)
                            print(f"{cc:5} {size:7} {kind:6} {format_name:4} {name:10} "
                                  f"Goose/C {g/c:.3f}  {size/g*1000:.1f} MB/s", flush=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
