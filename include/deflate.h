#ifndef GOOSE_DEFLATE_H
#define GOOSE_DEFLATE_H

// Like goose-simd, native builds inline the adapters in the generated C.
// TinyCC calls the same adapters compiled by the native toolchain instead.
#if !defined(__TINYC__)
#include "../vendor/libdeflate/libdeflate.h"
#include <stdint.h>
#include <string.h>
#include <limits.h>

#ifndef GDF_INLINE
#if defined(_MSC_VER)
#define GDF_INLINE static __forceinline
#elif defined(__GNUC__) || defined(__clang__)
#define GDF_INLINE static inline __attribute__((always_inline))
#else
#define GDF_INLINE static inline
#endif
#endif

GDF_INLINE uint64_t gdf_open_compressor(int32_t level) {
    return (uint64_t)(uintptr_t)libdeflate_alloc_compressor(level);
}
GDF_INLINE uint64_t gdf_open_decompressor(void) {
    return (uint64_t)(uintptr_t)libdeflate_alloc_decompressor();
}
GDF_INLINE void gdf_close_compressor(uint64_t handle) {
    libdeflate_free_compressor((struct libdeflate_compressor *)(uintptr_t)handle);
}
GDF_INLINE void gdf_close_decompressor(uint64_t handle) {
    libdeflate_free_decompressor((struct libdeflate_decompressor *)(uintptr_t)handle);
}

GDF_INLINE int64_t gdf_bound(uint64_t handle, int32_t format, int64_t size) {
    struct libdeflate_compressor *c = (struct libdeflate_compressor *)(uintptr_t)handle;
    size_t n;
    if (size < 0 || (uint64_t)size > SIZE_MAX) return -1;
    switch (format) {
    case 0: n = libdeflate_deflate_compress_bound(c, (size_t)size); break;
    case 1: n = libdeflate_zlib_compress_bound(c, (size_t)size); break;
    default: n = libdeflate_gzip_compress_bound(c, (size_t)size); break;
    }
    return n > INT64_MAX ? -1 : (int64_t)n;
}

GDF_INLINE int64_t gdf_compress(uint64_t handle, int32_t format, sl_u8 input, sl_u8 output) {
    struct libdeflate_compressor *c = (struct libdeflate_compressor *)(uintptr_t)handle;
    // libdeflate requires valid buffer pointers even for zero-byte buffers.
    unsigned char dummy = 0;
    const void *in = input.len ? input.data : &dummy;
    void *out = output.len ? output.data : &dummy;
    switch (format) {
    case 0: return (int64_t)libdeflate_deflate_compress(c, in, (size_t)input.len, out, (size_t)output.len);
    case 1: return (int64_t)libdeflate_zlib_compress(c, in, (size_t)input.len, out, (size_t)output.len);
    default: return (int64_t)libdeflate_gzip_compress(c, in, (size_t)input.len, out, (size_t)output.len);
    }
}

GDF_INLINE int32_t gdf_decompress(uint64_t handle, int32_t format, sl_u8 input, sl_u8 output, sl_i64 counts) {
    struct libdeflate_decompressor *d = (struct libdeflate_decompressor *)(uintptr_t)handle;
    size_t consumed = 0, written = 0;
    enum libdeflate_result status;
    unsigned char dummy = 0;
    const void *in = input.len ? input.data : &dummy;
    void *out = output.len ? output.data : &dummy;
    switch (format) {
    case 0: status = libdeflate_deflate_decompress_ex(d, in, (size_t)input.len, out, (size_t)output.len, &consumed, &written); break;
    case 1: status = libdeflate_zlib_decompress_ex(d, in, (size_t)input.len, out, (size_t)output.len, &consumed, &written); break;
    default: status = libdeflate_gzip_decompress_ex(d, in, (size_t)input.len, out, (size_t)output.len, &consumed, &written); break;
    }
    // Goose arrays may be packed: never hand their elements to size_t* APIs.
    int64_t result[2] = {0, 0};
    if (status == LIBDEFLATE_SUCCESS) {
        result[0] = (int64_t)consumed;
        result[1] = (int64_t)written;
    }
    memcpy(counts.data, result, sizeof result);
    return (int32_t)status;
}

GDF_INLINE uint32_t gdf_crc32(sl_u8 bytes, uint32_t initial) {
    // libdeflate treats NULL as reset, not an empty incremental update.
    return bytes.len ? libdeflate_crc32(initial, bytes.data, (size_t)bytes.len) : initial;
}
GDF_INLINE uint32_t gdf_adler32(sl_u8 bytes, uint32_t initial) {
    return bytes.len ? libdeflate_adler32(initial, bytes.data, (size_t)bytes.len) : initial;
}
#undef GDF_INLINE
#endif
#endif
