#include "czlib_shim.h"
#include <zlib.h>

static int map_strategy(FBZlibStrategy strategy) {
    switch (strategy) {
        case FBZlibStrategyFiltered: return Z_FILTERED;
        case FBZlibStrategyHuffmanOnly: return Z_HUFFMAN_ONLY;
        case FBZlibStrategyRLE: return Z_RLE;
        case FBZlibStrategyFixed: return Z_FIXED;
        case FBZlibStrategyDefault:
        default:
            return Z_DEFAULT_STRATEGY;
    }
}

size_t fb_zlib_compress_bound(size_t inputLength) {
    return (size_t)compressBound((uLong)inputLength) + 64;
}

int64_t fb_zlib_compress(
    const uint8_t *input,
    size_t inputLength,
    uint8_t *output,
    size_t outputCapacity,
    int level,
    FBZlibStrategy strategy
) {
    if (!input || !output || outputCapacity == 0) {
        return -1;
    }

    z_stream stream;
    stream.zalloc = Z_NULL;
    stream.zfree = Z_NULL;
    stream.opaque = Z_NULL;

    int clampedLevel = level < 0 ? 0 : (level > 9 ? 9 : level);
    int rc = deflateInit2(
        &stream,
        clampedLevel,
        Z_DEFLATED,
        15,
        8,
        map_strategy(strategy)
    );
    if (rc != Z_OK) {
        return -1;
    }

    stream.next_in = (Bytef *)input;
    stream.avail_in = (uInt)inputLength;
    stream.next_out = (Bytef *)output;
    stream.avail_out = (uInt)outputCapacity;

    rc = deflate(&stream, Z_FINISH);
    size_t totalOut = (size_t)stream.total_out;
    deflateEnd(&stream);

    if (rc != Z_STREAM_END) {
        return -1;
    }
    return (int64_t)totalOut;
}

uint32_t fb_crc32(uint32_t initial, const uint8_t *data, size_t length) {
    return (uint32_t)crc32((uLong)initial, (const Bytef *)data, (uInt)length);
}
