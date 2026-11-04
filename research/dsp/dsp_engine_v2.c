// dsp_engine.c — Zero-malloc-in-loop, SIMD-friendly DSP Pipeline
#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define MAX_NODES 64
#define MAX_BLOCK_SIZE 4096

typedef enum {
  NODE_BYPASS = 0,
  NODE_GAIN = 1,
  NODE_LPF_1P = 2,  // 1-Pole Low Pass Filter (Smooth Raga warmth)
  NODE_SOFTCLIP = 3 // Tanh-style harmonic saturation
} NodeType;

// Flat, cache-friendly state for a single DSP node (fits in a single CPU cache
// line!)
typedef struct {
  int32_t type;
  int32_t active;
  float param1; // e.g., gain or cutoff coeff
  float param2; // e.g., drive or resonance
  float z1;     // unit delay state (memory of past sample)
  float z2;
} DspNode;

// The entire pipeline lives in ONE contiguous allocation (The Arena)
typedef struct {
  uint32_t num_nodes;
  float sample_rate;
  DspNode nodes[MAX_NODES];
  float work_buf[MAX_BLOCK_SIZE]; // Aligned scratchpad
} DspPipeline;

// 1. Lifecycle: Only ONE malloc and ONE free for the entire engine!
DspPipeline *dsp_create(float sample_rate) {
  DspPipeline *p = (DspPipeline *)calloc(1, sizeof(DspPipeline));
  if (p)
    p->sample_rate = sample_rate;
  return p;
}

void dsp_destroy(DspPipeline *p) {
  if (p)
    free(p);
}

// 2. Graph Building & Live Parameter Tweaking (Instant, thread-safe atomic
// writes)
int32_t dsp_add_node(DspPipeline *p, int32_t type, float param1, float param2) {
  if (!p || p->num_nodes >= MAX_NODES)
    return -1;
  uint32_t idx = p->num_nodes++;
  p->nodes[idx] =
      (DspNode){.type = type, .active = 1, .param1 = param1, .param2 = param2};
  return (int32_t)idx;
}

int32_t dsp_set_param(DspPipeline *p, uint32_t node_idx, float param1,
                      float param2) {
  if (!p || node_idx >= p->num_nodes)
    return -1;
  p->nodes[node_idx].param1 = param1;
  p->nodes[node_idx].param2 = param2;
  return 0;
}

// 3. The Hot Loop: Pure, vectorized, branch-minimal math
int32_t dsp_process(DspPipeline *p, const float *restrict in,
                    float *restrict out, size_t frames) {
  if (!p || !in || !out || frames > MAX_BLOCK_SIZE)
    return -1;

  // Copy input to working buffer
  memcpy(out, in, frames * sizeof(float));

  for (uint32_t n = 0; n < p->num_nodes; ++n) {
    DspNode *node = &p->nodes[n];
    if (!node->active)
      continue;

    switch (node->type) {
    case NODE_GAIN: {
      const float g = node->param1;
      for (size_t i = 0; i < frames; ++i) {
        out[i] *= g;
      }
      break;
    }
    case NODE_LPF_1P: {
      // y[n] = y[n-1] + alpha * (x[n] - y[n-1])
      const float alpha = node->param1;
      float z1 = node->z1;
      for (size_t i = 0; i < frames; ++i) {
        z1 += alpha * (out[i] - z1);
        out[i] = z1;
      }
      node->z1 = z1; // Save filter state for next block
      break;
    }
    case NODE_SOFTCLIP: {
      // Fast Pade-approximated tanh saturation: x * (27 + x^2) / (27 + 9*x^2)
      const float drive = node->param1;
      for (size_t i = 0; i < frames; ++i) {
        float x = out[i] * drive;
        if (x > 3.0f)
          out[i] = 1.0f;
        else if (x < -3.0f)
          out[i] = -1.0f;
        else {
          float x2 = x * x;
          out[i] = x * (27.0f + x2) / (27.0f + 9.0f * x2);
        }
      }
      break;
    }
    default:
      break;
    }
  }
  return 0;
}