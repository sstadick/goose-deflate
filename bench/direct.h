#ifndef GDF_BENCH_DIRECT_H
#define GDF_BENCH_DIRECT_H
#include "../vendor/libdeflate/libdeflate.h"
#include <stdlib.h>

// Direct C baseline in the SAME executable, using the SAME handles, buffers,
// library, compiler, and optimization flags. No separate library copy or LTO.
#define COMPRESS_LOOP(format) \
    for (int64_t i = 0; i < iterations; ++i) { \
        size_t n = libdeflate_##format##_compress(c, input.data, (size_t)input.len, output.data, (size_t)output.len); \
        if (!n) abort(); \
        sum += n; \
    }
#define DECOMPRESS_LOOP(format) \
    for (int64_t i = 0; i < iterations; ++i) { \
        size_t consumed, written; \
        if (libdeflate_##format##_decompress_ex(d, input.data, (size_t)input.len, output.data, (size_t)output.len, &consumed, &written) != LIBDEFLATE_SUCCESS) abort(); \
        if (consumed != (size_t)input.len || written != (size_t)output.len) abort(); \
        sum += consumed + written; \
    }

static uint64_t direct_compress(uint64_t handle, int32_t format, sl_u8 input, sl_u8 output, int64_t iterations) {
    struct libdeflate_compressor *c = (struct libdeflate_compressor *)(uintptr_t)handle;
    uint64_t sum = 0;
    switch (format) {
    case 0: COMPRESS_LOOP(deflate); break;
    case 1: COMPRESS_LOOP(zlib); break;
    default: COMPRESS_LOOP(gzip); break;
    }
    return sum;
}
static uint64_t direct_decompress(uint64_t handle, int32_t format, sl_u8 input, sl_u8 output, int64_t iterations) {
    struct libdeflate_decompressor *d = (struct libdeflate_decompressor *)(uintptr_t)handle;
    uint64_t sum = 0;
    switch (format) {
    case 0: DECOMPRESS_LOOP(deflate); break;
    case 1: DECOMPRESS_LOOP(zlib); break;
    default: DECOMPRESS_LOOP(gzip); break;
    }
    return sum;
}
static uint64_t direct_checksum(int32_t operation, sl_u8 input, int64_t iterations) {
    uint64_t sum = 0;
    if (operation == 2) {
        for (int64_t i = 0; i < iterations; ++i)
            sum += libdeflate_crc32(0, input.data, (size_t)input.len);
    } else {
        for (int64_t i = 0; i < iterations; ++i)
            sum += libdeflate_adler32(1, input.data, (size_t)input.len);
    }
    return sum;
}
#undef COMPRESS_LOOP
#undef DECOMPRESS_LOOP
#endif
