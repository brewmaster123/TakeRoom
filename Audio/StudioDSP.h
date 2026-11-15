#ifndef STUDIO_DSP_H
#define STUDIO_DSP_H
#include <stdint.h>

typedef struct {
    int64_t skip, start, count;
} TRWindow;
// Clip a decoded block to the song timeline in stereo sample frames.
TRWindow tr_window(int64_t start, int64_t count, int64_t total);
int tr_blank_wave(const char *path, int64_t frames);
// Input tracks are canonical 44.1 kHz, 16-bit stereo WAVs produced by tr_blank_wave.
// Arrays are in beat, lead, backing 1, backing 2 order.
int tr_mix(const char *directory, const char *out, int64_t frames, const float gain[4], const float room[4]);
int tr_pack(const char *directory, const char *out);
typedef struct {
    float gain, room, compression, low, mid, high, drive, blend;
} TREffect;
typedef struct {
    int64_t start, end;
} TRCut;
int tr_produce(const char *dir, int64_t frames, const TREffect *fx, float duck, float density,
               const TRCut *cuts, int ncuts, int exportStems);
int tr_pack_processed(const char *directory, const char *out);
typedef struct {
    double bpm, anchor;
    int root, minor;
} TRGrid;
TRGrid tr_analyze(const float *pcm, int n, double rate);
typedef struct TRLive TRLive;
TRLive *tr_live_open(const char *directory, int64_t frames);
void tr_live_close(TRLive *live);
void tr_live_update(TRLive *live, const TREffect *fx, const int64_t *shifts, float duck, float density,
                    const TRCut *cuts, int ncuts);
void tr_live_transport(TRLive *live, int64_t frame, int playing, int loop, int64_t start, int64_t end);
int64_t tr_live_position(TRLive *live);
void tr_live_render(TRLive *live, float *left, float *right, int count);
typedef struct {
    int lag;
    double score, margin;
} TRMatch;
TRMatch tr_match(const float *reference, int n, const float *candidate, int m, int minimum, int maximum,
                 int separation);
#endif
