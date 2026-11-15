#define _POSIX_C_SOURCE 200809L
#include "StudioDSP.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

static const char *names[] = {"01-beat.wav",  "02-lead.wav", "03-back-1.wav", "04-back-2.wav",
                              "00-video.mp4", "Master.wav",  "Acapella.wav"};
static FILE *track(const char *dir, int lane) {
    size_t n = strlen(dir) + strlen(names[lane]) + 2;
    char *path = malloc(n);
    if (!path)
        return NULL;
    snprintf(path, n, "%s/%s", dir, names[lane]);
    FILE *f = fopen(path, "rb");
    free(path);
    return f;
}
static void u16(FILE *f, uint16_t x) {
    fputc(x & 255, f);
    fputc(x >> 8, f);
}
static void u32(FILE *f, uint32_t x) {
    u16(f, (uint16_t)x);
    u16(f, (uint16_t)(x >> 16));
}
static void wave_header(FILE *f, uint32_t frames) {
    uint32_t bytes = frames * 4;
    fwrite("RIFF", 1, 4, f);
    u32(f, bytes + 36);
    fwrite("WAVEfmt ", 1, 8, f);
    u32(f, 16);
    u16(f, 1);
    u16(f, 2);
    u32(f, 44100);
    u32(f, 176400);
    u16(f, 4);
    u16(f, 16);
    fwrite("data", 1, 4, f);
    u32(f, bytes);
}
TRWindow tr_window(int64_t start, int64_t count, int64_t total) {
    if (count <= 0 || total <= 0 || start >= total || start <= -count)
        return (TRWindow){0, 0, 0};
    int64_t skip = start < 0 ? -start : 0;
    int64_t dest = start < 0 ? 0 : start;
    int64_t length = count - skip;
    if (length > total - dest)
        length = total - dest;
    return (TRWindow){skip, dest, length};
}
int tr_blank_wave(const char *path, int64_t frames) {
    if (frames <= 0 || frames > (UINT32_MAX - 36u) / 4u)
        return -1;
    FILE *f = fopen(path, "wb");
    if (!f)
        return -1;
    wave_header(f, (uint32_t)frames);
    int bad = fseek(f, 44 + frames * 4 - 1, SEEK_SET) || fputc(0, f) == EOF || ferror(f);
    if (fclose(f))
        bad = 1;
    return bad ? -1 : 0;
}
// Three parallel feedback delay lines per channel. Each vocal has its own send.
// This small room and the mixer run offline, so monitoring never feeds the mic back.
enum { blockSize = 1024, ringSize = 4096 };
typedef struct {
    float line[3][2][ringSize];
    unsigned cursor;
} Room;
static float ambience(Room *r, float sample, int channel) {
    const unsigned delay[3][2] = {{1297, 1499}, {2063, 2399}, {3079, 3469}};
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
    if (frames <= 0 || frames > (UINT32_MAX - 36u) / 4u)
        return -1;
    FILE *files[4] = {NULL}, *dst = NULL;
    Room *room = calloc(1, sizeof(Room));
    int ok = 0;
    if (!room)
        goto done;
    for (int t = 0; t < 4; t++) {
        files[t] = track(directory, t);
        if (!files[t] || fseek(files[t], 44, SEEK_SET))
            goto done;
    }
    if (!(dst = fopen(out, "wb")))
        goto done;
    wave_header(dst, (uint32_t)frames);
    for (int64_t pos = 0; pos < frames; pos += blockSize) {
        size_t n = frames - pos < blockSize ? (size_t)(frames - pos) : blockSize;
        int16_t pcm[4][blockSize * 2], mixed[blockSize * 2];
        for (int t = 0; t < 4; t++)
            if (fread(pcm[t], 4, n, files[t]) != n)
                goto done;
        for (size_t i = 0; i < n; i++, room->cursor++) {
            for (int ch = 0; ch < 2; ch++) {
                float dry = 0, send = 0;
                size_t k = i * 2 + (size_t)ch;
                for (int t = 0; t < 4; t++) {
                    float x = (float)pcm[t][k] * gains[t];
                    dry += x;
                    send += x * wet[t];
                }
                float total = dry + ambience(room, send, ch);
                // Soft knee only on peaks; lower levels remain unchanged.
                float mag = fabsf(total);
                if (mag > 30000)
                    total = copysignf(30000 + 2767 * tanhf((mag - 30000) / 2767), total);
                mixed[k] = (int16_t)lrintf(total);
            }
        }
        if (fwrite(mixed, 4, n, dst) != n)
            goto done;
    }
    ok = !ferror(dst);
done:
    for (int t = 0; t < 4; t++)
        if (files[t])
            fclose(files[t]);
    if (dst && fclose(dst))
        ok = 0;
    free(room);
    if (!ok)
        remove(out);
    return ok ? 0 : -1;
}
static FILE *named_file(const char *directory, const char *name, const char *mode) {
    size_t n = strlen(directory) + strlen(name) + 2;
    char *path = malloc(n);
    if (!path)
        return NULL;
    snprintf(path, n, "%s/%s", directory, name);
    FILE *f = fopen(path, mode);
    free(path);
    return f;
}

static int16_t sample16(float value) { return (int16_t)lrintf(fminf(32767, fmaxf(-32768, value))); }

typedef struct {
    Room room;
    float bass[2], treble[2], envelope;
} VoiceState;

static float follow(float current, float peak) {
    return current + (peak - current) * (peak > current ? 0.0045f : 0.00019f);
}

// The same processor is used by the preview and the exported files.
#include <fcntl.h>
#include <pthread.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

typedef struct {
    VoiceState voices[4];
    float detector, bus, vocalBus;
} MixState;

static float limit_bus(float x, float envelope, float density) {
    if (density <= 0)
        return x;
    float gain = 1 + density * 2;
    if (envelope > 0.5f)
        gain *= powf(0.5f / envelope, 0.45f * density);
    x *= gain;
    if (fabsf(x) > 30000)
        x = copysignf(30000 + 2767 * tanhf((fabsf(x) - 30000) / 2767), x);
    return x;
}

static void process_frame(MixState *state, const TREffect *fx, float duck, float density, const TRCut *cuts,
                          int ncuts, int64_t frame, float samples[4][2], float master[2], float acapella[2]) {
    float sum[2] = {0}, voice[2] = {0};
    float beatGain = 1;
    for (int i = 0; i < ncuts; i++) {
        if (frame < cuts[i].start || frame >= cuts[i].end)
            continue;
        float distance = (float)fmin(frame - cuts[i].start, cuts[i].end - 1 - frame);
        beatGain = fminf(beatGain, fmaxf(0, 1 - distance / 120));
    }
    for (int k = 1; k <= 4; k++) {
        int t = k % 4;
        VoiceState *v = &state->voices[t];
        const TREffect *e = &fx[t];
        float peak = fmaxf(fabsf(samples[t][0]), fabsf(samples[t][1])) / 32768;
        v->envelope = follow(v->envelope, peak);
        float reduction = 1;
        if (e->compression > 0 && v->envelope > 0.16f)
            reduction = powf(0.16f / v->envelope, 0.75f * e->compression);
        if (t == 1)
            state->detector = follow(state->detector, peak * e->gain);
        for (int ch = 0; ch < 2; ch++) {
            float x = samples[t][ch] / 32768 * reduction;
            if (t) {
                x *= 1 + 0.3f * e->compression;
                v->bass[ch] += 0.035f * (x - v->bass[ch]);
                v->treble[ch] += 0.348f * (x - v->treble[ch]);
                x = e->low * v->bass[ch] + e->mid * (v->treble[ch] - v->bass[ch]) +
                    e->high * (x - v->treble[ch]);
                if (e->blend > 0 && e->drive > 0)
                    x += (tanhf(x * (1 + 15 * e->drive)) - x) * e->blend;
                x += ambience(&v->room, x * e->room, ch);
            } else {
                x *= beatGain * (1 - duck * fminf(1, state->detector * 5) * 0.78f);
            }
            samples[t][ch] = sample16(x * e->gain * 32768);
            sum[ch] += samples[t][ch];
            if (t)
                voice[ch] += samples[t][ch];
        }
        v->room.cursor++;
    }
    state->bus = follow(state->bus, fmaxf(fabsf(sum[0]), fabsf(sum[1])) / 32768);
    state->vocalBus = follow(state->vocalBus, fmaxf(fabsf(voice[0]), fabsf(voice[1])) / 32768);
    for (int ch = 0; ch < 2; ch++) {
        master[ch] = sample16(limit_bus(sum[ch], state->bus, density));
        acapella[ch] = sample16(limit_bus(voice[ch], state->vocalBus, density));
    }
}

int tr_produce(const char *dir, int64_t frames, const TREffect *fx, float duck, float density,
               const TRCut *cuts, int ncuts, int exportStems) {
    if (frames <= 0 || frames > (UINT32_MAX - 36u) / 4u)
        return -1;
    MixState *state = calloc(1, sizeof(MixState));
    FILE *input[4] = {0}, *stem[4] = {0}, *master = NULL, *vocals = NULL;
    int ok = 0;
    if (!state)
        return -1;
    for (int k = 0; k < 4; k++) {
        input[k] = track(dir, k);
        if (!input[k] || fseek(input[k], 44, SEEK_SET))
            goto done;
        if (exportStems) {
            char name[64];
            snprintf(name, sizeof(name), "processed-%s", names[k]);
            stem[k] = named_file(dir, name, "wb");
            if (!stem[k])
                goto done;
            wave_header(stem[k], (uint32_t)frames);
        }
    }
    master = named_file(dir, "Master.wav", "wb");
    if (!master)
        goto done;
    wave_header(master, (uint32_t)frames);
    if (exportStems) {
        vocals = named_file(dir, "Acapella.wav", "wb");
        if (!vocals)
            goto done;
        wave_header(vocals, (uint32_t)frames);
    }
    for (int64_t pos = 0; pos < frames; pos += blockSize) {
        size_t n = (size_t)(frames - pos < blockSize ? frames - pos : blockSize);
        int16_t pcm[4][2 * blockSize], mix[2 * blockSize], aca[2 * blockSize];
        for (int k = 0; k < 4; k++)
            if (fread(pcm[k], 4, n, input[k]) != n)
                goto done;
        for (size_t i = 0; i < n; i++) {
            float samples[4][2], main[2], voice[2];
            for (int k = 0; k < 4; k++)
                for (int ch = 0; ch < 2; ch++)
                    samples[k][ch] = pcm[k][2 * i + ch];
            process_frame(state, fx, duck, density, cuts, ncuts, pos + (int64_t)i, samples, main, voice);
            for (int ch = 0; ch < 2; ch++) {
                mix[2 * i + ch] = (int16_t)main[ch];
                aca[2 * i + ch] = (int16_t)voice[ch];
                for (int k = 0; k < 4; k++)
                    pcm[k][2 * i + ch] = (int16_t)samples[k][ch];
            }
        }
        if (fwrite(mix, 4, n, master) != n || (vocals && fwrite(aca, 4, n, vocals) != n))
            goto done;
        for (int k = 0; k < 4; k++)
            if (stem[k] && fwrite(pcm[k], 4, n, stem[k]) != n)
                goto done;
    }
    ok = 1;
done:
    for (int k = 0; k < 4; k++) {
        if (input[k])
            fclose(input[k]);
        if (stem[k] && fclose(stem[k]))
            ok = 0;
    }
    if (master && fclose(master))
        ok = 0;
    if (vocals && fclose(vocals))
        ok = 0;
    free(state);
    return ok ? 0 : -1;
}

struct TRLive {
    pthread_mutex_t mutex;
    MixState state;
    const unsigned char *maps[4];
    size_t sizes[4];
    int64_t shifts[4], previousShifts[4], position, frames, loopStart, loopEnd;
    int fade[4];
    TREffect fx[4];
    TRCut *cuts;
    int ncuts, playing, loop;
    float duck, density;
};

void tr_live_close(TRLive *live) {
    if (!live)
        return;
    for (int k = 0; k < 4; k++)
        if (live->maps[k])
            munmap((void *)live->maps[k], live->sizes[k]);
    free(live->cuts);
    pthread_mutex_destroy(&live->mutex);
    free(live);
}
TRLive *tr_live_open(const char *dir, int64_t frames) {
    TRLive *live = calloc(1, sizeof(TRLive));
    if (!live)
        return NULL;
    pthread_mutex_init(&live->mutex, NULL);
    live->frames = frames;
    for (int k = 0; k < 4; k++) {
        FILE *file = track(dir, k);
        struct stat info;
        if (!file) {
            tr_live_close(live);
            return NULL;
        }
        int status = fstat(fileno(file), &info);
        if (status || info.st_size < 44 + frames * 4) {
            fclose(file);
            tr_live_close(live);
            return NULL;
        }
        live->sizes[k] = (size_t)info.st_size;
        void *bytes = mmap(NULL, live->sizes[k], PROT_READ, MAP_PRIVATE, fileno(file), 0);
        fclose(file);
        if (bytes == MAP_FAILED) {
            tr_live_close(live);
            return NULL;
        }
        live->maps[k] = bytes;
    }
    return live;
}
void tr_live_update(TRLive *live, const TREffect *fx, const int64_t *shifts, float duck, float density,
                    const TRCut *cuts, int ncuts) {
    TRCut *copy = ncuts ? malloc((size_t)ncuts * sizeof(TRCut)) : NULL;
    if (ncuts && !copy)
        return;
    if (ncuts)
        memcpy(copy, cuts, (size_t)ncuts * sizeof(TRCut));
    pthread_mutex_lock(&live->mutex);
    memcpy(live->fx, fx, sizeof(live->fx));
    for (int k = 0; k < 4; k++)
        if (live->shifts[k] != shifts[k]) {
            live->previousShifts[k] = live->shifts[k];
            live->fade[k] = 128;
        }
    memcpy(live->shifts, shifts, sizeof(live->shifts));
    TRCut *old = live->cuts;
    live->cuts = copy;
    live->ncuts = ncuts;
    live->duck = duck;
    live->density = density;
    pthread_mutex_unlock(&live->mutex);
    free(old);
}
void tr_live_transport(TRLive *live, int64_t frame, int playing, int loop, int64_t start, int64_t end) {
    pthread_mutex_lock(&live->mutex);
    live->position = frame < 0 ? 0 : frame > live->frames ? live->frames : frame;
    live->playing = playing;
    live->loop = loop;
    live->loopStart = start;
    live->loopEnd = end;
    memset(&live->state, 0, sizeof(live->state));
    memset(live->fade, 0, sizeof(live->fade));
    pthread_mutex_unlock(&live->mutex);
}
int64_t tr_live_position(TRLive *live) {
    pthread_mutex_lock(&live->mutex);
    int64_t position = live->position;
    pthread_mutex_unlock(&live->mutex);
    return position;
}
void tr_live_render(TRLive *live, float *left, float *right, int count) {
    memset(left, 0, (size_t)count * sizeof(float));
    memset(right, 0, (size_t)count * sizeof(float));
    // UI updates never block the real-time render thread.
    if (pthread_mutex_trylock(&live->mutex))
        return;
    for (int i = 0; i < count && live->playing; i++) {
        int64_t end = live->loop ? live->loopEnd : live->frames;
        if (live->position >= end) {
            if (!live->loop) {
                live->playing = 0;
                break;
            }
            live->position = live->loopStart;
            memset(&live->state, 0, sizeof(live->state));
        }
        float samples[4][2] = {{0}}, master[2], acapella[2];
        for (int k = 0; k < 4; k++) {
            int64_t frame = live->position - live->shifts[k];
            int64_t old = live->position - live->previousShifts[k];
            const int16_t *pcm = (const int16_t *)(live->maps[k] + 44);
            for (int ch = 0; ch < 2; ch++) {
                float value = frame >= 0 && frame < live->frames ? pcm[2 * frame + ch] : 0;
                if (live->fade[k]) {
                    float previous = old >= 0 && old < live->frames ? pcm[2 * old + ch] : 0;
                    value += (previous - value) * live->fade[k] / 128;
                }
                samples[k][ch] = value;
            }
            if (live->fade[k])
                live->fade[k]--;
        }
        process_frame(&live->state, live->fx, live->duck, live->density, live->cuts, live->ncuts,
                      live->position, samples, master, acapella);
        left[i] = master[0] / 32768;
        right[i] = master[1] / 32768;
        live->position++;
    }
    pthread_mutex_unlock(&live->mutex);
}

// ZIP32 STORE streams media without buffering it in memory. Sizes/checksums go
// into the local headers and the central directory.
typedef struct {
    uint32_t crc, size, offset;
} Entry;
static int pack(const char *directory, const char *out, int count) {
    Entry entries[7] = {0};
    FILE *zip = fopen(out, "wb"), *src = NULL;
    unsigned char buf[65536];
    int ok = 0;
    if (!zip)
        return -1;
    for (int i = 0; i < count; i++) {
        size_t len = strlen(names[i]), got;
        long off = ftell(zip);
        if (off < 0 || (unsigned long)off > UINT32_MAX)
            goto done;
        entries[i].offset = (uint32_t)off;
        u32(zip, 0x04034b50);
        u16(zip, 20);
        u16(zip, 0);
        u16(zip, 0);
        u16(zip, 0);
        u16(zip, 33);
        u32(zip, 0);
        u32(zip, 0);
        u32(zip, 0);
        u16(zip, (uint16_t)len);
        u16(zip, 0);
        fwrite(names[i], 1, len, zip);
        src = track(directory, i);
        if (!src)
            goto done;
        while ((got = fread(buf, 1, sizeof(buf), src))) {
            if (got > UINT32_MAX - entries[i].size || fwrite(buf, 1, got, zip) != got)
                goto done;
            entries[i].size += (uint32_t)got;
            entries[i].crc = (uint32_t)crc32(entries[i].crc, buf, (uInt)got);
        }
        if (ferror(src))
            goto done;
        fclose(src);
        src = NULL;
        if (fseek(zip, off + 14, SEEK_SET))
            goto done;
        u32(zip, entries[i].crc);
        u32(zip, entries[i].size);
        u32(zip, entries[i].size);
        if (fseek(zip, 0, SEEK_END))
            goto done;
    }
    long central = ftell(zip);
    if (central < 0 || (unsigned long)central > UINT32_MAX)
        goto done;
    for (int i = 0; i < count; i++) {
        Entry e = entries[i];
        size_t len = strlen(names[i]);
        u32(zip, 0x02014b50);
        u16(zip, 20);
        u16(zip, 20);
        u16(zip, 0);
        u16(zip, 0);
        u16(zip, 0);
        u16(zip, 33);
        u32(zip, e.crc);
        u32(zip, e.size);
        u32(zip, e.size);
        u16(zip, (uint16_t)len);
        u16(zip, 0);
        u16(zip, 0);
        u16(zip, 0);
        u16(zip, 0);
        u32(zip, 0);
        u32(zip, e.offset);
        fwrite(names[i], 1, len, zip);
    }
    long end = ftell(zip);
    if (end < central || (unsigned long)end > UINT32_MAX)
        goto done;
    u32(zip, 0x06054b50);
    u16(zip, 0);
    u16(zip, 0);
    u16(zip, count);
    u16(zip, count);
    u32(zip, (uint32_t)(end - central));
    u32(zip, (uint32_t)central);
    u16(zip, 0);
    ok = !ferror(zip);
done:
    if (src)
        fclose(src);
    if (fclose(zip))
        ok = 0;
    if (!ok)
        remove(out);
    return ok ? 0 : -1;
}

int tr_pack(const char *directory, const char *out) { return pack(directory, out, 5); }
int tr_pack_processed(const char *directory, const char *out) { return pack(directory, out, 7); }

// Analyse mono PCM resampled by the caller to about 8 kHz. Windowed FFT supplies
// both spectral flux (tempo) and a folded pitch-class histogram (key).
TRGrid tr_analyze(const float *pcm, int n, double rate) {
    enum { N = 1024 };
    TRGrid result = {0, 0, -1, 0};
    int hop = (int)lrint(rate / 100), bins = hop > 0 ? (n - N) / hop : 0;
    if (bins < 200 || rate < 4000)
        return result;
    double previous[N / 2] = {0}, chroma[12] = {0}, power[N / 2];
    double *flux = calloc((size_t)bins, sizeof(double));
    if (!flux)
        return result;
    for (int b = 0; b < bins; b++) {
        double re[N], im[N] = {0};
        for (int i = 0, j = 0; i < N; i++) {
            re[j] = pcm[b * hop + i] * (0.5 - 0.5 * cos(6.283185307 * i / N));
            int bit = N >> 1;
            while (bit && (j & bit)) {
                j ^= bit;
                bit >>= 1;
            }
            j ^= bit;
        }
        for (int len = 2; len <= N; len *= 2) {
            double a = -6.283185307 / len, wr = cos(a), wi = sin(a);
            for (int k = 0; k < N; k += len) {
                double r = 1, v = 0;
                for (int j = 0; j < len / 2; j++) {
                    int x = k + j, y = x + len / 2;
                    double dr = re[y] * r - im[y] * v, di = re[y] * v + im[y] * r;
                    re[y] = re[x] - dr;
                    im[y] = im[x] - di;
                    re[x] += dr;
                    im[x] += di;
                    double next = r * wr - v * wi;
                    v = v * wr + r * wi;
                    r = next;
                }
            }
        }
        for (int k = 1; k < N / 2; k++) {
            power[k] = hypot(re[k], im[k]);
            double level = log1p(power[k]);
            flux[b] += fmax(0, level - previous[k]);
            previous[k] = level;
        }
        for (int k = 3; k < N / 2 - 1; k++) {
            double hz = k * rate / N;
            if (hz < 80 || hz > 2400 || power[k] < 0.1 || power[k] <= power[k - 1] || power[k] < power[k + 1])
                continue;
            double adj = 0.5 * (power[k - 1] - power[k + 1]) / (power[k - 1] - 2 * power[k] + power[k + 1]);
            int note = (int)lrint(69 + 12 * log2((k + adj) * rate / (N * 440)));
            chroma[note % 12] += power[k];
        }
    }
    double energy = 0, best = 0;
    int lag = 0;
    for (int i = 0; i < bins; i++)
        energy += flux[i] * flux[i];
    for (int d = 30; d <= 100; d++) {
        double score = 0;
        for (int i = d; i < bins; i++)
            score += flux[i] * flux[i - d];
        if (score > best) {
            best = score;
            lag = d;
        }
    }
    if (lag >= 60) {
        double shorter = 0;
        int selected = 0;
        for (int d = lag / 2 - 1; d <= lag / 2 + 1; d++) {
            if (d < 30)
                continue;
            double score = 0;
            for (int i = d; i < bins; i++)
                score += flux[i] * flux[i - d];
            if (score > shorter) {
                shorter = score;
                selected = d;
            }
        }
        if (shorter > best * 0.78) {
            best = shorter;
            lag = selected;
        }
    }
    if (lag && best > energy * 0.28) {
        double adjusted = lag;
        if (lag > 30 && lag < 100) {
            double left = 0, right = 0;
            for (int i = lag - 1; i < bins; i++)
                left += flux[i] * flux[i - lag + 1];
            for (int i = lag + 1; i < bins; i++)
                right += flux[i] * flux[i - lag - 1];
            double curvature = left - 2 * best + right;
            if (fabs(curvature) > 1e-12)
                adjusted += fmax(-0.5, fmin(0.5, 0.5 * (left - right) / curvature));
        }
        result.bpm = fmax(60, fmin(200, 60 * rate / (hop * adjusted)));
        double strongest = 0;
        for (int phase = 0; phase < lag; phase++) {
            double score = 0;
            for (int i = phase; i < bins; i += lag)
                score += flux[i];
            if (score > strongest) {
                strongest = score;
                result.anchor = (phase * hop + N / 2) / rate;
            }
        }
    }
    const double profiles[2][12] = {{6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88},
                                    {6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17}};
    double mean = 0, top = 0, second = 0;
    for (int i = 0; i < 12; i++)
        mean += chroma[i] / 12;
    for (int mode = 0; mode < 2; mode++)
        for (int root = 0; root < 12; root++) {
            double m = 0, dot = 0, x2 = 0, y2 = 0;
            for (int i = 0; i < 12; i++)
                m += profiles[mode][i] / 12;
            for (int i = 0; i < 12; i++) {
                double x = chroma[(i + root) % 12] - mean, y = profiles[mode][i] - m;
                dot += x * y;
                x2 += x * x;
                y2 += y * y;
            }
            double score = dot / sqrt(1e-12 + x2 * y2);
            if (score > top) {
                second = top;
                top = score;
                result.root = root;
                result.minor = mode;
            } else if (score > second)
                second = score;
        }
    if (top < 0.55 || top - second < 0.045)
        result.root = -1;
    free(flux);
    return result;
}

// Positive lag means that the candidate occurs later than the reference.
TRMatch tr_match(const float *reference, int n, const float *candidate, int m, int minimum, int maximum,
                 int separation) {
    TRMatch match = {0, 0, 0};
    if (n < 20 || m < 20 || maximum < minimum)
        return match;
    int total = maximum - minimum + 1;
    double *scores = calloc((size_t)total, sizeof(double));
    if (!scores)
        return match;
    for (int lag = minimum; lag <= maximum; lag++) {
        int lo = lag < 0 ? -lag : 0;
        int hi = n < m - lag ? n : m - lag;
        if (hi - lo < n / 2 || hi - lo < 20)
            continue;
        double xy = 0, xx = 0, yy = 0, x = 0, y = 0;
        for (int i = lo; i < hi; i++) {
            double a = reference[i], b = candidate[i + lag];
            xy += a * b;
            xx += a * a;
            yy += b * b;
            x += a;
            y += b;
        }
        int count = hi - lo;
        double score = (xy - x * y / count) / sqrt(fmax(1e-18, (xx - x * x / count) * (yy - y * y / count)));
        scores[lag - minimum] = score;
        if (score > match.score) {
            match.lag = lag;
            match.score = score;
        }
    }
    double runner = 0;
    for (int lag = minimum; lag <= maximum; lag++)
        if (abs(lag - match.lag) > separation)
            runner = fmax(runner, scores[lag - minimum]);
    match.margin = match.score - runner;
    free(scores);
    return match;
}
