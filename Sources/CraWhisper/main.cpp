// CraWhisper: Cra's transcription process. Cra hands it a 16 kHz mono WAV (the audio of a
// downloaded media file, decoded by Swift via AVFoundation) plus the pinned whisper GGML,
// and it prints the transcript segments to stdout — one "[mm:ss] text" line per segment.
// One-shot: it exits when done, so a Mac that stops transcribing gets its memory back. It
// never opens a socket and never reads a model outside the path it was started with.
//
// usage: CraWhisper <model.bin> <wav> [language]   language: "zh"/"en"/"auto"

#include "whisper.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

// Minimal RIFF/WAVE reader for what Cra writes: 16 kHz mono, float32 or int16 PCM.
static bool read_wav_mono_16k(const char * path, std::vector<float> & samples) {
    FILE * f = fopen(path, "rb");
    if (!f) return false;
    char riff[4];
    if (fread(riff, 1, 4, f) != 4 || memcmp(riff, "RIFF", 4) != 0) { fclose(f); return false; }
    fseek(f, 4, SEEK_CUR);  // size
    char wave[4];
    if (fread(wave, 1, 4, f) != 4 || memcmp(wave, "WAVE", 4) != 0) { fclose(f); return false; }

    uint16_t channels = 1, bits = 0;
    bool is_float = false;
    bool found_data = false;
    std::vector<char> data;

    while (!found_data) {
        char id[4];
        uint32_t size = 0;
        if (fread(id, 1, 4, f) != 4) break;
        if (fread(&size, 1, 4, f) != 4) break;
        if (memcmp(id, "fmt ", 4) == 0) {
            char fmt[16];
            if (size < 16 || fread(fmt, 1, 16, f) != 16) break;
            uint16_t format = uint16_t(fmt[0]) | (uint16_t(fmt[1]) << 8);
            channels = uint16_t(fmt[2]) | (uint16_t(fmt[3]) << 8);
            bits = uint16_t(fmt[14]) | (uint16_t(fmt[15]) << 8);
            is_float = format == 3;
            if (size > 16) fseek(f, size - 16, SEEK_CUR);
        } else if (memcmp(id, "data", 4) == 0) {
            data.resize(size);
            if (fread(data.data(), 1, size, f) != size) break;
            found_data = true;
        } else {
            fseek(f, size + (size & 1), SEEK_CUR);
        }
    }
    fclose(f);
    if (!found_data || channels != 1 || bits == 0) return false;

    const size_t count = data.size() / (bits / 8);
    samples.resize(count);
    if (bits == 32 && is_float) {
        memcpy(samples.data(), data.data(), count * 4);
    } else if (bits == 16) {
        for (size_t i = 0; i < count; i++) {
            int16_t v;
            memcpy(&v, data.data() + i * 2, 2);
            samples[i] = v / 32768.0f;
        }
    } else {
        return false;
    }
    return true;
}

int main(int argc, char ** argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: CraWhisper <model.bin> <wav> [language]\n");
        return 2;
    }
    const char * model_path = argv[1];
    const char * wav_path = argv[2];
    const char * language = argc > 3 ? argv[3] : "zh";

    whisper_context_params cparams = whisper_context_default_params();
    // CPU only on Intel (the Radeon crashes in decode); no Core ML dependency.
    whisper_context * ctx = whisper_init_from_file_with_params(model_path, cparams);
    if (!ctx) {
        fprintf(stderr, "CraWhisper: cannot load %s\n", model_path);
        return 1;
    }

    std::vector<float> pcm;
    if (!read_wav_mono_16k(wav_path, pcm) || pcm.empty()) {
        fprintf(stderr, "CraWhisper: cannot read the WAV (%s)\n", wav_path);
        whisper_free(ctx);
        return 1;
    }

    whisper_full_params wparams = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    wparams.language = language;
    wparams.print_progress = false;
    wparams.print_special = false;
    wparams.print_realtime = false;
    wparams.print_timestamps = true;
    wparams.single_segment = false;

    if (whisper_full(ctx, wparams, pcm.data(), static_cast<int>(pcm.size())) != 0) {
        fprintf(stderr, "CraWhisper: transcription failed\n");
        whisper_free(ctx);
        return 1;
    }

    const int n = whisper_full_n_segments(ctx);
    for (int i = 0; i < n; i++) {
        const int64_t t0 = whisper_full_get_segment_t0(ctx, i);
        const int64_t t1 = whisper_full_get_segment_t1(ctx, i);
        const char * text = whisper_full_get_segment_text(ctx, i);
        // [mm:ss] text — Swift formats these into the transcript markdown.
        printf("[%02lld:%02lld] %s\n", t0 / 60000, (t0 / 1000) % 60, text);
    }
    whisper_free(ctx);
    return 0;
}
