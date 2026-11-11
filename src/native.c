#include <stdint.h>

// Goose's packed slice ABI. The generated C already defines these types;
// this translation unit supplies them for the TinyCC-callable adapters.
#pragma pack(push, 1)
typedef struct { uint8_t *data; int64_t len; } sl_u8;
typedef struct { int64_t *data; int64_t len; } sl_i64;
#pragma pack(pop)
#define GDF_INLINE
#include "../include/deflate.h"
