#include <stdint.h>

#ifdef __wasm__
  #define EXPORT(name) __attribute__((export_name(#name)))
#else
  #define EXPORT(name) __attribute__((visibility("default")))
#endif

// 16-Byte CRDT Binary Delta Packet (Conflict-Free across out-of-order network packets!)
typedef struct __attribute__((packed)) {
  uint8_t  opcode;        // 1 = EQ/Mod, 2 = MIDI Note, 3 = DJ Filter
  uint8_t  actor_id;      // Unique Collaborator ID (0..255)
  uint16_t item_id;       // Parameter / Note index
  uint32_t lamport_clock; // Monotonic Logical Clock for deterministic CRDT resolution!
  float    param_a;       // Value (e.g., EQ Gain / Mod Depth)
  float    param_b;       // Secondary Value
} CrdtDeltaPacket;

typedef struct {
  float    eq_gain[16];
  uint32_t eq_clock[16];  // CRDT Last-Writer-Wins Lamport Clock per parameter
  uint8_t  eq_actor[16];  // Tie-breaker Actor ID if two edits happen at the exact same clock tick!
  float    vu_peak;
  float    wave_scope[128];
  float    audio_io[128];
} DawCrdtState;

static DawCrdtState state;

EXPORT(get_audio_io_ptr)
float* get_audio_io_ptr(void) { return state.audio_io; }

// MATHEMATICAL CRDT MERGE IN PURE C:
// Commutative & Idempotent! Even if network packets arrive out of order,
// every browser and server converges to the exact same state.
EXPORT(apply_crdt_delta)
int apply_crdt_delta(const CrdtDeltaPacket* pkt) {
  if (pkt->opcode == 1 && pkt->item_id < 16) {
    uint16_t idx = pkt->item_id;
    uint32_t current_clock = state.eq_clock[idx];

    // Accept update ONLY if Lamport clock is newer (or equal clock with higher actor_id tie-breaker)
    if (pkt->lamport_clock > current_clock ||
       (pkt->lamport_clock == current_clock && pkt->actor_id >= state.eq_actor[idx])) {
      state.eq_gain[idx]  = pkt->param_a;
      state.eq_clock[idx] = pkt->lamport_clock;
      state.eq_actor[idx] = pkt->actor_id;
      return 1; // Delta won and updated state!
    }
  }
  return 0; // Stale out-of-order packet safely ignored by CRDT!
}

EXPORT(process_block)
float process_block(uint32_t frames, float master_gain) {
  float peak = 0.0f;
  float eq0 = state.eq_gain[0] != 0.0f ? state.eq_gain[0] : 1.0f;

  for (uint32_t i = 0; i < frames; i++) {
    float s = state.audio_io[i] * eq0 * master_gain;
    state.audio_io[i] = s;
    state.wave_scope[i] = s;
    float abs_s = s < 0.0f ? -s : s;
    if (abs_s > peak) peak = abs_s;
  }
  state.vu_peak = peak;
  return peak;
}
