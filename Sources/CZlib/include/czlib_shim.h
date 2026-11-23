#ifndef CZLIB_SHIM_H
#define CZLIB_SHIM_H

#include <stdint.h>
#include <stddef.h>

typedef enum {
    FBZlibStrategyDefault = 0,
    FBZlibStrategyFiltered = 1,
    FBZlibStrategyHuffmanOnly = 2,
    FBZlibStrategyRLE = 3,
    FBZlibStrategyFixed = 4
} FBZlibStrategy;

/// Compresses `input` bytes into a standard zlib stream (2-byte header + deflate + Adler-32 trailer).
/// Returns compressed byte length on success, or -1 on error / insufficient output capacity.
int64_t fb_zlib_compress(
    const uint8_t *input,
    size_t inputLength,
    uint8_t *output,
    size_t outputCapacity,
    int level,
    FBZlibStrategy strategy
);

/// Computes IEEE 802.3 CRC-32 for PNG chunk verification.
uint32_t fb_crc32(uint32_t initial, const uint8_t *data, size_t length);

/// Upper bound on compressed output size for `inputLength`.
size_t fb_zlib_compress_bound(size_t inputLength);

#endif
