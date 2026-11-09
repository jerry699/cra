// CraInferenceHelper: Cra's local model process. Swift starts it for a rename, it loads the
// pinned GGUF with llama.cpp, answers, and exits after `idle` seconds without a request, so a
// Mac that stops tidying gets its memory back. It never opens a socket and never reads a model
// outside the path it was started with.
//
// Protocol (little-endian, stdin/stdout, one request at a time):
//   request:  u32 magic 'CRQL', u8 op, u8 pad[3], u32 max_tokens,
//             u32 sys_len, sys bytes, u32 user_len, user bytes   (op 0)
//             u32 sys_len, sys bytes, u32 user_len, user bytes,
//             u32 grammar_len, grammar bytes                     (op 3, GBNF held sampling)
//   response: u32 magic 'CRSL', u8 status, u8 pad[3], u32 len, text bytes
// op 1 = ping ("pong"), op 2 = exit. Any read error or EOF ends the process.
//
// Qwen3.5 is a hybrid SSM model: llama_memory_seq_rm cannot rewind its state to a prefix, so a
// rename reuses the shared instruction/examples prefix through llama_state_seq_get_data /
// set_data (bench/reuse_test.cpp measured 19.6MB and 3-7ms to restore). The snapshot is only
// restored when the new token stream matches its prefix exactly.

#include "llama.h"

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <poll.h>
#include <unistd.h>
#include <vector>

static constexpr uint32_t kRequestMagic = 0x4C515243;   // "CRQL"
static constexpr uint32_t kResponseMagic = 0x4C534352;  // "CRSL"
// Set by argv[3]: 1024 holds a rename prompt, 4096 a two-stage Tidy Tabs prompt (1153 tokens)
// plus its assignment answer (about 700).
static int g_context = 1024;
// Set by argv[4]: 4 normally, 2 while the chassis is hot (the app pauses Tidy Tabs then, but
// renames still run).
static int g_threads = 4;
// The prompt is evaluated in chunks of this size; 256 keeps the CPU compute buffer small
// (about half of 512's 489MB), which matters on an 8GB Mac.
static constexpr int kBatch = 256;

static double now_ms() {
    using namespace std::chrono;
    return duration_cast<microseconds>(steady_clock::now().time_since_epoch()).count() / 1000.0;
}

static bool read_exact(int fd, void * out, size_t n) {
    auto * p = static_cast<char *>(out);
    size_t got = 0;
    while (got < n) {
        ssize_t r = ::read(fd, p + got, n - got);
        if (r > 0) { got += static_cast<size_t>(r); continue; }
        if (r == 0) return false;
        if (errno == EINTR) continue;
        return false;
    }
    return true;
}

static bool write_exact(int fd, const void * in, size_t n) {
    auto * p = static_cast<const char *>(in);
    size_t sent = 0;
    while (sent < n) {
        ssize_t r = ::write(fd, p + sent, n - sent);
        if (r > 0) { sent += static_cast<size_t>(r); continue; }
        if (r < 0 && errno == EINTR) continue;
        return false;
    }
    return true;
}

static bool read_u32(int fd, uint32_t & value) {
    unsigned char b[4];
    if (!read_exact(fd, b, 4)) return false;
    value = uint32_t(b[0]) | (uint32_t(b[1]) << 8) | (uint32_t(b[2]) << 16) | (uint32_t(b[3]) << 24);
    return true;
}

static bool read_string(int fd, std::string & value) {
    uint32_t n = 0;
    if (!read_u32(fd, n) || n > (64u << 20)) return false;
    value.resize(n);
    return n == 0 || read_exact(fd, value.data(), n);
}

static bool reply(int fd, uint8_t status, const std::string & text) {
    unsigned char header[12];
    const uint32_t magic = kResponseMagic;
    const uint32_t len = static_cast<uint32_t>(text.size());
    for (int i = 0; i < 4; i++) {
        header[i]     = (magic >> (8 * i)) & 0xFF;
        header[8 + i] = (len >> (8 * i)) & 0xFF;
    }
    header[4] = status;
    header[5] = header[6] = header[7] = 0;
    return write_exact(fd, header, sizeof(header)) &&
           (len == 0 || write_exact(fd, text.data(), len));
}

// Qwen3.5's chat template with enable_thinking=false, rendered the way llama-server did in the
// benchmarks: the assistant turn opens with an empty think block, so the model answers directly.
static std::string chat_prompt(const std::string & system, const std::string & user) {
    std::string out;
    out.reserve(system.size() + user.size() + 96);
    out += "<|im_start|>system\n";
    out += system;
    out += "<|im_end|>\n<|im_start|>user\n";
    out += user;
    out += "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n";
    return out;
}

struct Engine {
    llama_model * model = nullptr;
    llama_context * ctx = nullptr;
    const llama_vocab * vocab = nullptr;

    std::vector<llama_token> cached_tokens;
    std::vector<uint8_t> snapshot;
    int cached_prefix = 0;

    bool load(const std::string & path) {
        llama_backend_init();
        llama_model_params mp = llama_model_default_params();
        mp.use_mmap = true;
        mp.n_gpu_layers = 0;  // Intel + AMD: measured 7-13x slower on Metal, and it crashed.
        model = llama_model_load_from_file(path.c_str(), mp);
        if (!model) {
            fprintf(stderr, "CraInferenceHelper: cannot load %s\n", path.c_str());
            return false;
        }
        vocab = llama_model_get_vocab(model);

        llama_context_params cp = llama_context_default_params();
        cp.n_ctx = g_context;
        cp.n_threads = g_threads;
        cp.n_threads_batch = g_threads;
        cp.n_batch = kBatch;
        cp.n_ubatch = kBatch;
        ctx = llama_init_from_model(model, cp);
        if (!ctx) {
            fprintf(stderr, "CraInferenceHelper: cannot create a context\n");
            return false;
        }
        return true;
    }

    void unload() {
        if (ctx) { llama_free(ctx); ctx = nullptr; }
        if (model) { llama_model_free(model); model = nullptr; }
        vocab = nullptr;
        snapshot.clear();
        cached_tokens.clear();
        cached_prefix = 0;
        llama_backend_free();
    }

    std::vector<llama_token> tokenize(const std::string & text) const {
        std::vector<llama_token> out(text.size() + 32);
        int n = llama_tokenize(vocab, text.c_str(), static_cast<int32_t>(text.size()),
                               out.data(), static_cast<int32_t>(out.size()), false, true);
        if (n < 0) {
            out.resize(static_cast<size_t>(-n));
            n = llama_tokenize(vocab, text.c_str(), static_cast<int32_t>(text.size()),
                               out.data(), static_cast<int32_t>(out.size()), false, true);
        }
        if (n < 0) return {};
        out.resize(static_cast<size_t>(n));
        return out;
    }

    bool decode(const std::vector<llama_token> & toks, int pos0, int start, int count, bool last_logits) {
        for (int offset = 0; offset < count; offset += kBatch) {
            const int n = std::min(kBatch, count - offset);
            llama_batch batch = llama_batch_init(n, 0, 1);
            for (int i = 0; i < n; i++) {
                batch.token[i] = toks[static_cast<size_t>(start + offset + i)];
                batch.pos[i] = pos0 + offset + i;
                batch.n_seq_id[i] = 1;
                batch.seq_id[i][0] = 0;
                batch.logits[i] = (last_logits && offset + i + 1 == count) ? 1 : 0;
            }
            batch.n_tokens = n;
            const bool ok = llama_decode(ctx, batch) == 0;
            llama_batch_free(batch);
            if (!ok) return false;
        }
        return true;
    }

    std::string generate(const std::string & system, const std::string & user,
                         const std::string & grammar, int max_tokens) {
        const std::string prompt = chat_prompt(system, user);
        const std::vector<llama_token> toks = tokenize(prompt);
        if (toks.empty()) return {};

        int common = 0;
        const size_t shared = std::min(toks.size(), cached_tokens.size());
        while (static_cast<size_t>(common) < shared && toks[common] == cached_tokens[common]) common++;
        // The suffix must keep the last token: a restore alone brings no logits, so the sampler
        // needs at least one freshly decoded token. Identical prompts then reuse state up to
        // size-1 and only recompute the final token.
        if (static_cast<size_t>(common) >= toks.size()) common = static_cast<int>(toks.size()) - 1;

        bool restored = false;
        if (cached_prefix > 0 && common >= cached_prefix && !snapshot.empty()) {
            restored = llama_state_seq_set_data(ctx, snapshot.data(), snapshot.size(), 0) != 0;
        }
        const int start = restored ? cached_prefix : 0;
        if (!restored) llama_memory_clear(llama_get_memory(ctx), true);

        const double pp_started = now_ms();
        if (common > start && !decode(toks, start, start, common - start, false)) return {};
        // Keep the state at the shared prefix (not the prompt's changing last line) for next time.
        const size_t state_size = llama_state_seq_get_size(ctx, 0);
        snapshot.resize(state_size);
        if (state_size > 0 && llama_state_seq_get_data(ctx, snapshot.data(), snapshot.size(), 0) == 0) {
            snapshot.clear();
            cached_prefix = 0;
        } else {
            cached_prefix = common;
        }
        cached_tokens = toks;

        if (static_cast<size_t>(common) < toks.size() &&
            !decode(toks, common, common, static_cast<int>(toks.size()) - common, true)) return {};
        const double pp_ms = now_ms() - pp_started;

        // Greedy either way; a grammar (Tidy Tabs' JSON) rides in front of it in the chain.
        llama_sampler * sampler = llama_sampler_chain_init(llama_sampler_chain_default_params());
        if (!grammar.empty()) {
            llama_sampler * g = llama_sampler_init_grammar(vocab, grammar.c_str(), "root");
            if (!g) {
                fprintf(stderr, "CraInferenceHelper: the grammar did not parse; answering without it\n");
            } else {
                llama_sampler_chain_add(sampler, g);
            }
        }
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy());

        std::string out;
        int pos = static_cast<int>(toks.size());
        const int room = g_context - pos - 1;
        max_tokens = std::max(0, std::min(max_tokens, room));
        const double tg_started = now_ms();
        for (int i = 0; i < max_tokens; i++) {
            const llama_token token = llama_sampler_sample(sampler, ctx, -1);
            if (token == LLAMA_TOKEN_NULL || llama_vocab_is_eog(vocab, token)) break;
            char piece[128];
            const int n = llama_token_to_piece(vocab, token, piece, sizeof(piece), 0, false);
            if (n > 0) out.append(piece, static_cast<size_t>(n));
            if (!decode(std::vector<llama_token>{token}, pos, 0, 1, true)) break;
            pos++;
        }
        llama_sampler_free(sampler);
        fprintf(stderr,
                "CraInferenceHelper: prompt=%zu common=%d restore=%d grammar=%d pp=%.0fms tg=%.0fms out=%zu\n",
                toks.size(), common, restored ? 1 : 0, grammar.empty() ? 0 : 1,
                pp_ms, now_ms() - tg_started, out.size());
        return out;
    }
};

int main(int argc, char ** argv) {
    std::string model_path = argc > 1 ? argv[1] : "";
    if (model_path.empty()) {
        const char * env = std::getenv("CRA_LOCAL_MODEL");
        if (env) model_path = env;
    }
    if (model_path.empty()) {
        fprintf(stderr, "usage: CraInferenceHelper <model.gguf> [idle-seconds] [context] [threads]\n");
        return 2;
    }
    const int idle_seconds = argc > 2 ? std::max(1, std::atoi(argv[2])) : 60;
    g_context = argc > 3 ? std::max(256, std::atoi(argv[3])) : 1024;
    g_threads = argc > 4 ? std::clamp(std::atoi(argv[4]), 1, 8) : 4;

    Engine engine;
    bool loaded = false;
    auto last_activity = std::chrono::steady_clock::now();

    while (true) {
        pollfd waiting{STDIN_FILENO, POLLIN, 0};
        const int ready = poll(&waiting, 1, 1000);
        if (ready < 0 && errno == EINTR) continue;
        if (ready < 0) break;
        if (ready == 0) {
            if (std::chrono::steady_clock::now() - last_activity >= std::chrono::seconds(idle_seconds)) break;
            continue;
        }
        if (waiting.revents & (POLLHUP | POLLERR | POLLNVAL)) break;

        unsigned char header[12];
        if (!read_exact(STDIN_FILENO, header, sizeof(header))) break;
        const uint32_t magic = uint32_t(header[0]) | (uint32_t(header[1]) << 8) |
                               (uint32_t(header[2]) << 16) | (uint32_t(header[3]) << 24);
        if (magic != kRequestMagic) break;
        const uint8_t op = header[4];
        const uint32_t max_tokens = uint32_t(header[8]) | (uint32_t(header[9]) << 8) |
                                    (uint32_t(header[10]) << 16) | (uint32_t(header[11]) << 24);
        last_activity = std::chrono::steady_clock::now();

        if (op == 2) break;
        if (op == 1) {
            if (!reply(STDOUT_FILENO, 0, "pong")) break;
            continue;
        }
        std::string system, user, grammar;
        if (op == 3) {
            if (!read_string(STDIN_FILENO, system) || !read_string(STDIN_FILENO, user) ||
                !read_string(STDIN_FILENO, grammar)) break;
        } else if (op != 0 || !read_string(STDIN_FILENO, system) || !read_string(STDIN_FILENO, user)) {
            break;
        }

        if (!loaded) {
            const double started = now_ms();
            if (!engine.load(model_path)) {
                reply(STDOUT_FILENO, 1, "");
                break;
            }
            loaded = true;
            fprintf(stderr, "CraInferenceHelper: loaded in %.0fms\n", now_ms() - started);
        }

        const int limit = static_cast<int>(std::min<uint32_t>(max_tokens == 0 ? 32 : max_tokens, 2048));
        const std::string answer = engine.generate(system, user, grammar, limit);
        if (!reply(STDOUT_FILENO, answer.empty() ? 1 : 0, answer)) break;
    }

    engine.unload();
    return 0;
}
