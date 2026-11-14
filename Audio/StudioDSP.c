#define _POSIX_C_SOURCE 200809L
#include "StudioDSP.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <zlib.h>

static const char *names[] = {"01-beat.wav", "02-lead.wav", "03-back-1.wav", "04-back-2.wav", "00-video.mp4"};
static FILE *track(const char *dir, int lane) {
    size_t n = strlen(dir) + strlen(names[lane]) + 2;
    char *path = malloc(n);
    if (!path) return NULL;
    snprintf(path, n, "%s/%s", dir, names[lane]);
    FILE *f = fopen(path, "rb");
    free(path);
    return f;
}
static void u16(FILE *f, uint16_t x) { fputc(x & 255, f); fputc(x >> 8, f); }
static void u32(FILE *f, uint32_t x) { u16(f, (uint16_t)x); u16(f, (uint16_t)(x >> 16)); }
static void wave_header(FILE *f, uint32_t frames) {
    uint32_t bytes = frames * 4;
    fwrite("RIFF", 1, 4, f); u32(f, bytes + 36);
    fwrite("WAVEfmt ", 1, 8, f); u32(f, 16);
    u16(f, 1); u16(f, 2); u32(f, 44100); u32(f, 176400);
    u16(f, 4); u16(f, 16); fwrite("data", 1, 4, f); u32(f, bytes);
}
TRWindow tr_window(int64_t start, int64_t count, int64_t total) {
    if (count <= 0 || total <= 0 || start >= total || start <= -count)
        return (TRWindow){0, 0, 0};
    int64_t skip = start < 0 ? -start : 0;
    int64_t dest = start < 0 ? 0 : start;
    int64_t length = count - skip;
    if (length > total - dest) length = total - dest;
    return (TRWindow){skip, dest, length};
}
int tr_blank_wave(const char *path, int64_t frames) {
    if (frames <= 0 || frames > (UINT32_MAX - 36u) / 4u) return -1;
    FILE *f = fopen(path, "wb");
    if (!f) return -1;
    wave_header(f, (uint32_t)frames);
    int bad = fseek(f, 44 + frames * 4 - 1, SEEK_SET) || fputc(0, f) == EOF || ferror(f);
    if (fclose(f)) bad = 1;
    return bad ? -1 : 0;
}
// Three parallel feedback delay lines per channel. Each vocal has its own send.
// This small room and the mixer run offline, so monitoring never feeds the mic back.
enum { blockSize = 1024, ringSize = 4096 };
typedef struct { float line[3][2][ringSize]; unsigned cursor; } Room;
static float ambience(Room *r, float sample, int channel) {
    const unsigned delay[3][2] = {{1297,1499}, {2063,2399}, {3079,3469}};
    float sum = 0;
    unsigned write = r->cursor & (ringSize - 1);
    for (int d = 0; d < 3; d++) {
        unsigned read = (r->cursor - delay[d][channel]) & (ringSize - 1);
        float echo = r->line[d][channel][read];
        r->line[d][channel][write] = sample + 0.45f * echo;
        sum += echo;
    }
    return sum * 0.33f;
}
int tr_mix(const char *directory, const char *out, int64_t frames, const float gains[4], const float wet[4]) {
    if (frames <= 0 || frames > (UINT32_MAX - 36u) / 4u) return -1;
    FILE *files[4] = {NULL}, *dst = NULL;
    Room *room = calloc(1, sizeof(Room));
    int ok = 0;
    if (!room) goto done;
    for (int t = 0; t < 4; t++) {
        files[t] = track(directory, t);
        if (!files[t] || fseek(files[t], 44, SEEK_SET)) goto done;
    }
    if (!(dst = fopen(out, "wb"))) goto done;
    wave_header(dst, (uint32_t)frames);
    for (int64_t pos = 0; pos < frames; pos += blockSize) {
        size_t n = frames - pos < blockSize ? (size_t)(frames - pos) : blockSize;
        int16_t pcm[4][blockSize * 2], mixed[blockSize * 2];
        for (int t = 0; t < 4; t++)
            if (fread(pcm[t], 4, n, files[t]) != n) goto done;
        for (size_t i = 0; i < n; i++, room->cursor++) {
            for (int ch = 0; ch < 2; ch++) {
                float dry = 0, send = 0;
                size_t k = i * 2 + (size_t)ch;
                for (int t = 0; t < 4; t++) {
                    float x = (float)pcm[t][k] * gains[t];
                    dry += x; send += x * wet[t];
                }
                float total = dry + ambience(room, send, ch);
                // Soft knee only on peaks; lower levels remain unchanged.
                float mag = fabsf(total);
                if (mag > 30000) total = copysignf(30000 + 2767 * tanhf((mag - 30000) / 2767), total);
                mixed[k] = (int16_t)lrintf(total);
            }
        }
        if (fwrite(mixed, 4, n, dst) != n) goto done;
    }
    ok = !ferror(dst);
done:
    for (int t = 0; t < 4; t++) if (files[t]) fclose(files[t]);
    if (dst && fclose(dst)) ok = 0;
    free(room);
    if (!ok) remove(out);
    return ok ? 0 : -1;
}
// ZIP32 STORE streams media without buffering it in memory. Sizes/checksums go
// into the local headers and the central directory.
typedef struct { uint32_t crc, size, offset; } Entry;
int tr_pack(const char *directory, const char *out) {
    Entry entries[5] = {0};
    FILE *zip = fopen(out, "wb"), *src = NULL;
    unsigned char buf[65536];
    int ok = 0;
    if (!zip) return -1;
    for (int i = 0; i < 5; i++) {
        size_t len = strlen(names[i]), got;
        long off = ftell(zip);
        if (off < 0 || (unsigned long)off > UINT32_MAX) goto done;
        entries[i].offset = (uint32_t)off;
        u32(zip, 0x04034b50); u16(zip, 20); u16(zip, 0); u16(zip, 0);
        u16(zip, 0); u16(zip, 33); u32(zip, 0); u32(zip, 0); u32(zip, 0);
        u16(zip, (uint16_t)len); u16(zip, 0); fwrite(names[i], 1, len, zip);
        src = track(directory, i);
        if (!src) goto done;
        while ((got = fread(buf, 1, sizeof(buf), src))) {
            if (got > UINT32_MAX - entries[i].size || fwrite(buf, 1, got, zip) != got) goto done;
            entries[i].size += (uint32_t)got;
            entries[i].crc = (uint32_t)crc32(entries[i].crc, buf, (uInt)got);
        }
        if (ferror(src)) goto done;
        fclose(src); src = NULL;
        if (fseek(zip, off + 14, SEEK_SET)) goto done;
        u32(zip, entries[i].crc); u32(zip, entries[i].size); u32(zip, entries[i].size);
        if (fseek(zip, 0, SEEK_END)) goto done;
    }
    long central = ftell(zip);
    if (central < 0 || (unsigned long)central > UINT32_MAX) goto done;
    for (int i = 0; i < 5; i++) {
        Entry e = entries[i]; size_t len = strlen(names[i]);
        u32(zip, 0x02014b50); u16(zip, 20); u16(zip, 20); u16(zip, 0); u16(zip, 0);
        u16(zip, 0); u16(zip, 33); u32(zip, e.crc); u32(zip, e.size); u32(zip, e.size);
        u16(zip, (uint16_t)len); u16(zip, 0); u16(zip, 0); u16(zip, 0); u16(zip, 0);
        u32(zip, 0); u32(zip, e.offset); fwrite(names[i], 1, len, zip);
    }
    long end = ftell(zip);
    if (end < central || (unsigned long)end > UINT32_MAX) goto done;
    u32(zip, 0x06054b50); u16(zip, 0); u16(zip, 0); u16(zip, 5); u16(zip, 5);
    u32(zip, (uint32_t)(end - central)); u32(zip, (uint32_t)central); u16(zip, 0);
    ok = !ferror(zip);
done:
    if (src) fclose(src);
    if (fclose(zip)) ok = 0;
    if (!ok) remove(out);
    return ok ? 0 : -1;
}
