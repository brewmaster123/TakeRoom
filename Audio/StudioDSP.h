#ifndef STUDIO_DSP_H
#define STUDIO_DSP_H
#include <stdint.h>

typedef struct { int64_t skip, start, count; } TRWindow;
// Clip a decoded block to the song timeline in stereo sample frames.
TRWindow tr_window(int64_t start, int64_t count, int64_t total);
int tr_blank_wave(const char *path, int64_t frames);
// Input tracks are canonical 44.1 kHz, 16-bit stereo WAVs produced by tr_blank_wave.
// Arrays are in beat, lead, backing 1, backing 2 order.
int tr_mix(const char *directory, const char *out, int64_t frames,
           const float gain[4], const float room[4]);
int tr_pack(const char *directory, const char *out);
#endif
