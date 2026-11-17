// unzl: unpacks a file compressed with OpenZL (https://github.com/facebook/openzl, BSD), Zstandard
// or xz, for content a Quest app downloads packed that way (QuestAppFiles.swift,
// `halliday.files.unpack`), so a Mac needs no other tool (macOS carries neither xz nor zstd).
//
//   unzl IN OUT        progress on stdout, a whole percentage a line; 0 on success
//
// Told apart by how the file starts:
//   - Zstandard frames (28 B5 2F FD), by the zstd library OpenZL is built on;
//   - xz (FD 37 7A 58 5A 00), by Apple's Compression framework (its LZMA is the xz format);
//   - one OpenZL frame;
//   - a file cut in pieces, each its own frame, so a large file unpacks piece by piece:
//       "SANT", u32 version (1), u64 piece size, u64 whole size, u32 pieces,
//       then for each piece u64 packed size and u64 unpacked size, then the frames end to end
//     (little-endian, no padding).
//
// Built by `make unzl` against reference/openzl (tools/fetch-reference.sh); OpenZL is linked
// in, nothing of it is in Halliday's sources.

#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <compression.h>
#include <zstd.h>

#include "openzl/zl_decompress.h"
#include "openzl/zl_errors.h"

typedef struct {
    uint64_t from, packed, to, unpacked;
} Piece;

static uint32_t u32_at(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static uint64_t u64_at(const uint8_t *p) { uint64_t v; memcpy(&v, p, 8); return v; }

static int fail(const char *what) {
    fprintf(stderr, "unzl: %s\n", what);
    return 1;
}

// Zstandard and xz: one stream, read through and written out a buffer at a time, the progress
// by how much of the input has been read.
enum { CHUNK = 1 << 20 };
static int told_percent = -1;
static void tell(uint64_t read, uint64_t size) {
    int percent = (int)(read * 99 / size);
    if (percent > told_percent) { told_percent = percent; printf("%d\n", percent); fflush(stdout); }
}
static int write_all(int fd, const uint8_t *p, size_t n) {
    while (n > 0) {
        ssize_t w = write(fd, p, n);
        if (w <= 0) return 0;
        p += w; n -= (size_t)w;
    }
    return 1;
}

static int unpack_zstd(const uint8_t *src, uint64_t size, int out) {
    ZSTD_DCtx *ctx = ZSTD_createDCtx();
    uint8_t *buf = malloc(CHUNK);
    if (!ctx || !buf) return fail("out of memory");
    ZSTD_DCtx_setParameter(ctx, ZSTD_d_windowLogMax, 31);
    ZSTD_inBuffer in = { src, size, 0 };
    size_t last = 0;
    while (in.pos < in.size) {
        ZSTD_outBuffer o = { buf, CHUNK, 0 };
        last = ZSTD_decompressStream(ctx, &o, &in);
        if (ZSTD_isError(last)) return fail("the Zstandard data is damaged");
        if (!write_all(out, buf, o.pos)) return fail("the output can't be written");
        tell(in.pos, size);
    }
    // zstd keeps a frame's last byte until all of its output is out, so once all is read,
    // all is written; a frame left open (`last` not 0) was cut short.
    if (last != 0) return fail("the Zstandard data is cut short");
    return 0;
}

static int unpack_xz(const uint8_t *src, uint64_t size, int out) {
    compression_stream s;
    if (compression_stream_init(&s, COMPRESSION_STREAM_DECODE, COMPRESSION_LZMA) != COMPRESSION_STATUS_OK)
        return fail("xz can't be read on this Mac");
    uint8_t *buf = malloc(CHUNK);
    if (!buf) return fail("out of memory");
    s.src_ptr = src;
    s.src_size = size;
    for (;;) {
        s.dst_ptr = buf;
        s.dst_size = CHUNK;
        compression_status status = compression_stream_process(&s, COMPRESSION_STREAM_FINALIZE);
        if (status == COMPRESSION_STATUS_ERROR) { compression_stream_destroy(&s); return fail("the xz data is damaged"); }
        if (!write_all(out, buf, CHUNK - s.dst_size)) return fail("the output can't be written");
        tell(size - s.src_size, size);
        if (status == COMPRESSION_STATUS_END) break;
        if (s.src_size == 0 && s.dst_size == CHUNK) { compression_stream_destroy(&s); return fail("the xz data is cut short"); }
    }
    compression_stream_destroy(&s);
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 3) return fail("usage: unzl IN OUT");
    int in = open(argv[1], O_RDONLY);
    struct stat st;
    if (in < 0 || fstat(in, &st) != 0) return fail("the input can't be read");
    uint64_t size = (uint64_t)st.st_size;
    if (size < 8) return fail("the input is too short");
    const uint8_t *src = mmap(NULL, size, PROT_READ, MAP_PRIVATE, in, 0);
    if (src == MAP_FAILED) return fail("the input can't be mapped");

    static const uint8_t zstd_magic[4] = { 0x28, 0xB5, 0x2F, 0xFD }, xz_magic[6] = { 0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00 };
    int is_zstd = memcmp(src, zstd_magic, 4) == 0, is_xz = memcmp(src, xz_magic, 6) == 0;
    if (is_zstd || is_xz) {
        madvise((void *)src, size, MADV_SEQUENTIAL);
        int out = open(argv[2], O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (out < 0) return fail("the output can't be written");
        int r = is_zstd ? unpack_zstd(src, size, out) : unpack_xz(src, size, out);
        if (close(out) != 0 && r == 0) r = fail("the output couldn't be written out");
        if (r != 0) { unlink(argv[2]); return r; }
        puts("100");
        return 0;
    }

    // The pieces: from the table, or the whole file as one.
    static Piece one;
    Piece *pieces = &one;
    uint64_t count = 1, whole = 0;
    if (memcmp(src, "SANT", 4) == 0) {
        if (size < 28 || u32_at(src + 4) != 1) return fail("a version of the pieces' table this doesn't know");
        whole = u64_at(src + 16);
        count = u32_at(src + 24);
        uint64_t at = 28 + 16 * count;
        if (count == 0 || at > size) return fail("the pieces' table is cut short");
        pieces = calloc(count, sizeof(Piece));
        if (!pieces) return fail("out of memory");
        uint64_t to = 0;
        for (uint64_t i = 0; i < count; i++) {
            const uint8_t *row = src + 28 + 16 * i;
            pieces[i] = (Piece){ at, u64_at(row), to, u64_at(row + 8) };
            if (pieces[i].packed > size - at) return fail("a piece runs past the end of the file");
            at += pieces[i].packed;
            to += pieces[i].unpacked;
        }
        if (to != whole) return fail("the pieces don't add up to the size the file gives");
    } else {
        ZL_Report r = ZL_getDecompressedSize(src, size);
        if (ZL_isError(r)) return fail("not an OpenZL file");
        whole = ZL_validResult(r);
        one = (Piece){ 0, size, 0, whole };
    }

    int out = open(argv[2], O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (out < 0 || ftruncate(out, (off_t)whole) != 0) return fail("the output can't be written");
    if (whole == 0) { puts("100"); return 0; }
    uint8_t *dst = mmap(NULL, whole, PROT_READ | PROT_WRITE, MAP_SHARED, out, 0);
    if (dst == MAP_FAILED) return fail("the output can't be mapped");

    __block atomic_ullong done = 0;
    __block atomic_int failed = 0, told = -1;
    dispatch_apply(count, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t i) {
        if (atomic_load(&failed)) return;
        Piece p = pieces[i];
        ZL_Report r = ZL_decompress(dst + p.to, p.unpacked, src + p.from, p.packed);
        if (ZL_isError(r) || ZL_validResult(r) != p.unpacked) {
            atomic_store(&failed, 1);
            return;
        }
        // What was read and written needn't stay in memory: the files are larger than it.
        madvise((void *)(src + (p.from & ~(uint64_t)16383)), p.packed, MADV_DONTNEED);
        msync(dst + p.to, p.unpacked, MS_ASYNC);
        uint64_t sum = atomic_fetch_add(&done, p.unpacked) + p.unpacked;
        int percent = (int)(sum * 99 / whole);
        int before = atomic_load(&told);
        while (percent > before && !atomic_compare_exchange_weak(&told, &before, percent)) {}
        if (percent > before) { printf("%d\n", percent); fflush(stdout); }
    });
    if (atomic_load(&failed)) {
        unlink(argv[2]);
        return fail("a piece couldn't be unpacked");
    }
    if (msync(dst, whole, MS_SYNC) != 0) return fail("the output couldn't be written out");
    puts("100");
    return 0;
}
