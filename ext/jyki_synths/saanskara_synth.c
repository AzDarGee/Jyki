// ext/jyki_synths/saanskara_synth.c
// Pure C99 Clay + NanoVG Synth with 48kHz Audio Engine, imgui-knobs WiperDot UI, ImPlot Scope & 4-Touch Limit!

#define CLAY_IMPLEMENTATION
#include "clay.h"

#include <GLES3/gl3.h>
#include <emscripten.h>
#include <emscripten/html5.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define NANOVG_GLES3_IMPLEMENTATION
#include "nanovg.h"
#include "nanovg_gl.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846f
#endif

// ============================================================================
// 1. STRICT 4-TOUCH LIMIT & PARAMETER DEFINITIONS
// ============================================================================
#define MAX_TOUCH_POINTS 4
#define NUM_PARAMS 5
#define SCOPE_POINTS 360

typedef struct {
    const char* name;
    const char* key;
    const char* fmt;
    float value;
    float min_val;
    float max_val;
    int is_slider;
    float bbox_x, bbox_y, bbox_w, bbox_h;
} SynthParam;

typedef struct {
    int active;
    int pointer_id;
    int param_index;
    float start_x;
    float start_y;
    float start_val;
} TouchSlot;

static SynthParam g_params[NUM_PARAMS] = {
    { "SA (HZ)",   "root_hz",      "%.0fHz", 240.0f, 110.0f, 440.0f, 0, 0,0,0,0 },
    { "JAWARI",    "jawari_buzz",  "%.2f",   0.42f,  0.0f,   1.0f,   0, 0,0,0,0 },
    { "TARAB RES", "resonance",    "%.2f",   0.68f,  0.0f,   1.0f,   0, 0,0,0,0 },
    { "DRIVE",     "analog_drive", "%.1fx",  1.65f,  0.5f,   4.0f,   0, 0,0,0,0 },
    { "MORPH MIX", "morph_slider", "%.2f",   0.75f,  0.0f,   1.0f,   1, 0,0,0,0 }
};

static TouchSlot g_touches[MAX_TOUCH_POINTS];
static NVGcontext* g_nvg = NULL;
static EMSCRIPTEN_WEBGL_CONTEXT_HANDLE g_gl = 0;
static char g_canvas_sel[64] = "#imgui-synth-canvas";
static float g_css_w = 800.0f, g_css_h = 240.0f;
static float g_last_mouse_x = 0.0f, g_last_mouse_y = 0.0f;
static float g_phase = 0.0f;

static NVGcolor g_col_canvas, g_col_surface, g_col_panel, g_col_accent, g_col_alert, g_col_text, g_col_muted;
static uint32_t g_hex_accent = 0xf59e0b, g_hex_alert = 0xe11d48, g_hex_text = 0xf8fafc;

EM_JS(void, js_emit_param, (const char* key, float val), {
    if (window.saanskaraOnImGuiParamChanged) {
        window.saanskaraOnImGuiParamChanged(UTF8ToString(key), val);
    }
});

static NVGcolor hex_to_nvg(uint32_t rgb, float a) {
    return nvgRGBA((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF, (unsigned char)(a * 255.0f));
}

static float clampf(float v, float lo, float hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

// ============================================================================
// 2. REAL-TIME 48kHz C99 CONTINUOUS AUDIO SYNTHESIZER (Defined BEFORE Touch!)
// ============================================================================
static float g_audio_sample_rate = 48000.0f;
static int   g_drone_active = 1; // Continuous sound ON by default!
static float g_phase_sa     = 0.0f;
static float g_phase_pa     = 0.0f;
static float g_phase_sub    = 0.0f;
static float g_phase_jawari = 0.0f;
static float g_phase_lfo    = 0.0f;
static float g_pluck_env    = 0.0f;
static float g_tarab_env    = 0.8f;
static float g_smooth_hz    = 240.0f;
static float g_smooth_jaw   = 0.42f;
static float g_smooth_res   = 0.68f;
static float g_smooth_drive = 1.65f;
static float g_smooth_morph = 0.75f;
static float g_meend_ratio  = 1.0f;
static float g_audio_out_buf[2048];

EMSCRIPTEN_KEEPALIVE
void synth_set_sample_rate(float sr) {
    if (sr >= 8000.0f && sr <= 192000.0f) g_audio_sample_rate = sr;
}

EMSCRIPTEN_KEEPALIVE
void synth_set_drone_active(int active) {
    g_drone_active = active ? 1 : 0;
}

EMSCRIPTEN_KEEPALIVE
int synth_get_drone_active(void) {
    return g_drone_active;
}

EMSCRIPTEN_KEEPALIVE
void synth_trigger_pluck(float velocity, float pitch_ratio) {
    g_pluck_env   = clampf(velocity, 0.2f, 1.0f);
    g_tarab_env   = 1.0f;
    g_meend_ratio = clampf(pitch_ratio, 0.5f, 2.0f);
}

EMSCRIPTEN_KEEPALIVE
float* synth_render_audio_block(int num_frames, int drone_override) {
    if (num_frames > 2048) num_frames = 2048;

    int is_on = (drone_override >= 0) ? drone_override : g_drone_active;
    float target_hz    = g_params[0].value * g_meend_ratio;
    float target_jaw   = g_params[1].value;
    float target_res   = g_params[2].value;
    float target_drive = g_params[3].value;
    float target_morph = g_params[4].value;
    float inv_sr       = 1.0f / g_audio_sample_rate;

    for (int i = 0; i < num_frames; i++) {
        // Sample-accurate parameter smoothing (zero clicks/zipper noise while turning knobs!)
        g_smooth_hz    += (target_hz    - g_smooth_hz)    * 0.002f;
        g_smooth_jaw   += (target_jaw   - g_smooth_jaw)   * 0.002f;
        g_smooth_res   += (target_res   - g_smooth_res)   * 0.002f;
        g_smooth_drive += (target_drive - g_smooth_drive) * 0.002f;
        g_smooth_morph += (target_morph - g_smooth_morph) * 0.002f;

        g_pluck_env *= 0.99980f;

        // Slow breathing Tanpura LFO so the continuous drone feels alive like plucked strings!
        g_phase_lfo += 2.0f * (float)M_PI * 0.35f * inv_sr;
        if (g_phase_lfo > 2.0f * (float)M_PI) g_phase_lfo -= 2.0f * (float)M_PI;
        float breath = 0.85f + 0.15f * sinf(g_phase_lfo);

        float drone_level = is_on ? (0.45f * breath) : 0.0f;
        float amp_env = fminf(1.2f, drone_level + g_pluck_env * 0.75f);

        // Advance oscillators controlled directly by Knob 0 (SA Hz)
        g_phase_sa     += 2.0f * (float)M_PI * g_smooth_hz * inv_sr;
        g_phase_pa     += 2.0f * (float)M_PI * (g_smooth_hz * 1.4983f) * inv_sr;
        g_phase_sub    += 2.0f * (float)M_PI * (g_smooth_hz * 0.5f) * inv_sr;
        g_phase_jawari += 2.0f * (float)M_PI * (g_smooth_hz * (2.0f + g_smooth_morph * 3.0f)) * inv_sr;

        if (g_phase_sa     > 2.0f * (float)M_PI) g_phase_sa     -= 2.0f * (float)M_PI;
        if (g_phase_pa     > 2.0f * (float)M_PI) g_phase_pa     -= 2.0f * (float)M_PI;
        if (g_phase_sub    > 2.0f * (float)M_PI) g_phase_sub    -= 2.0f * (float)M_PI;
        if (g_phase_jawari > 2.0f * (float)M_PI) g_phase_jawari -= 2.0f * (float)M_PI;

        // 1. Knob 0 (SA HZ) + Slider 4 (MORPH MIX: blends warm sub-drone vs bright upper sitar)
        float sa  = sinf(g_phase_sa);
        float sub = sinf(g_phase_sub) * (0.65f * (1.0f - g_smooth_morph * 0.6f));

        // 2. Knob 2 (TARAB RES: controls Fifth 'Pa' & 3rd/5th harmonic sympathetic strings!)
        float pa    = sinf(g_phase_pa) * (g_smooth_res * 0.65f);
        float tarab = sinf(g_phase_sa * 3.0f + 1.5f * pa) * (g_smooth_res * 0.40f);

        // 3. Knob 1 (JAWARI: controls curved-bridge FM harmonic buzz shimmer!)
        float buzz = g_smooth_jaw * 0.85f * sinf(g_phase_jawari + (1.0f + g_smooth_jaw * 3.5f) * sa);

        // 4. Knob 3 (DRIVE: controls analog tube saturation & output loudness!)
        float raw = (sa + sub + pa + tarab + buzz) * amp_env * g_smooth_drive;
        float out = raw / (1.0f + 0.50f * fabsf(raw));

        // Morph slider also acts as master output contour
        g_audio_out_buf[i] = out * (0.20f + 0.25f * g_smooth_morph);
    }

    return g_audio_out_buf;
}

// Direct sample getter so JS NEVER crashes even if HEAPF32 isn't exported!
EMSCRIPTEN_KEEPALIVE
float synth_get_audio_sample(int index) {
    return (index >= 0 && index < 2048) ? g_audio_out_buf[index] : 0.0f;
}

// ============================================================================
// 3. ZERO-DEPENDENCY GPU VECTOR HERSHEY MICRO-FONT
// ============================================================================
static void draw_glyph(char c, float x, float y, float w, float h) {
    if (c >= 'a' && c <= 'z') c -= 32;
    float mx = x + w * 0.5f, my = y + h * 0.5f, rx = x + w, by = y + h;

    switch (c) {
        case 'A': nvgMoveTo(g_nvg,x,by); nvgLineTo(g_nvg,mx,y); nvgLineTo(g_nvg,rx,by); nvgMoveTo(g_nvg,x+w*0.2f,my+h*0.15f); nvgLineTo(g_nvg,rx-w*0.2f,my+h*0.15f); break;
        case 'B': nvgMoveTo(g_nvg,x,y); nvgLineTo(g_nvg,x,by); nvgLineTo(g_nvg,rx,by-h*0.2f); nvgLineTo(g_nvg,mx,my); nvgLineTo(g_nvg,x,my); nvgMoveTo(g_nvg,mx,my); nvgLineTo(g_nvg,rx,y+h*0.2f); nvgLineTo(g_nvg,x,y); break;
        case 'C': nvgMoveTo(g_nvg,rx,y+h*0.2f); nvgLineTo(g_nvg,mx,y); nvgLineTo(g_nvg,x,y+h*0.2f); nvgLineTo(g_nvg,x,by-h*0.2f); nvgLineTo(g_nvg,mx,by); nvgLineTo(g_nvg,rx,by-h*0.2f); break;
        case 'D': nvgMoveTo(g_nvg,x,y); nvgLineTo(g_nvg,x,by); nvgLineTo(g_nvg,mx,by); nvgLineTo(g_nvg,rx,my); nvgLineTo(g_nvg,mx,y); nvgLineTo(g_nvg,x,y); break;
        case 'E': nvgMoveTo(g_nvg,rx,y); nvgLineTo(g_nvg,x,y); nvgLineTo(g_nvg,x,by); nvgLineTo(g_nvg,rx,by); nvgMoveTo(g_nvg,x,my); nvgLineTo(g_nvg,rx-w*0.2f,my); break;
        case 'F': nvgMoveTo(g_nvg,rx,y); nvgLineTo(g_nvg,x,y); nvgLineTo(g_nvg,x,by); nvgMoveTo(g_nvg,x,my); nvgLineTo(g_nvg,rx-w*0.2f,my); break;
        case 'G': nvgMoveTo(g_nvg,rx,y+h*0.2f); nvgLineTo(g_nvg,mx,y); nvgLineTo(g_nvg,x,y+h*0.2f); nvgLineTo(g_nvg,x,by-h*0.2f); nvgLineTo(g_nvg,rx,by); nvgLineTo(g_nvg,rx,my); nvgLineTo(g_nvg,mx,my); break;
        case 'H': nvgMoveTo(g_nvg,x,y); nvgLineTo(g_nvg,x,by); nvgMoveTo(g_nvg,rx,y); nvgLineTo(g_nvg,rx,by); nvgMoveTo(g_nvg,x,my); nvgLineTo(g_nvg,rx,my); break;
        case 'I': nvgMoveTo(g_nvg,x+w*0.2f,y); nvgLineTo(g_nvg,rx-w*0.2f,y); nvgMoveTo(g_nvg,mx,y); nvgLineTo(g_nvg,mx,by); nvgMoveTo(g_nvg,x+w*0.2f,by); nvgLineTo(g_nvg,rx-w*0.2f,by); break;
        case 'J': nvgMoveTo(g_nvg,rx,y); nvgLineTo(g_nvg,rx,by-h*0.2f); nvgLineTo(g_nvg,mx,by); nvgLineTo(g_nvg,x,by-h*0.2f); break;
        case 'K': nvgMoveTo(g_nvg,x,y); nvgLineTo(g_nvg,x,by); nvgMoveTo(g_nvg,rx,y); nvgLineTo(g_nvg,x,my); nvgLineTo(g_nvg,rx,by); break;
        case 'L': nvgMoveTo(g_nvg,x,y); nvgLineTo(g_nvg,x,by); nvgLineTo(g_nvg,rx,by); break;
        case 'M': nvgMoveTo(g_nvg,x,by); nvgLineTo(g_nvg,x,y); nvgLineTo(g_nvg,mx,my); nvgLineTo(g_nvg,rx,y); nvgLineTo(g_nvg,rx,by); break;
        case 'N': nvgMoveTo(g_nvg,x,by); nvgLineTo(g_nvg,x,y); nvgLineTo(g_nvg,rx,by); nvgLineTo(g_nvg,rx,y); break;
        case 'O': case '0': nvgMoveTo(g_nvg,x,y+h*0.2f); nvgLineTo(g_nvg,mx,y); nvgLineTo(g_nvg,rx,y+h*0.2f); nvgLineTo(g_nvg,rx,by-h*0.2f); nvgLineTo(g_nvg,mx,by); nvgLineTo(g_nvg,x,by-h*0.2f); nvgClosePath(g_nvg); break;
        case 'P': nvgMoveTo(g_nvg,x,by); nvgLineTo(g_nvg,x,y); nvgLineTo(g_nvg,rx,y); nvgLineTo(g_nvg,rx,my); nvgLineTo(g_nvg,x,my); break;
        case 'R': nvgMoveTo(g_nvg,x,by); nvgLineTo(g_nvg,x,y); nvgLineTo(g_nvg,rx,y); nvgLineTo(g_nvg,rx,my); nvgLineTo(g_nvg,x,my); nvgMoveTo(g_nvg,mx,my); nvgLineTo(g_nvg,rx,by); break;
        case 'S': case '5': nvgMoveTo(g_nvg,rx,y); nvgLineTo(g_nvg,x,y); nvgLineTo(g_nvg,x,my); nvgLineTo(g_nvg,rx,my); nvgLineTo(g_nvg,rx,by); nvgLineTo(g_nvg,x,by); break;
        case 'T': nvgMoveTo(g_nvg,x,y); nvgLineTo(g_nvg,rx,y); nvgMoveTo(g_nvg,mx,y); nvgLineTo(g_nvg,mx,by); break;
        case 'U': nvgMoveTo(g_nvg,x,y); nvgLineTo(g_nvg,x,by-h*0.2f); nvgLineTo(g_nvg,mx,by); nvgLineTo(g_nvg,rx,by-h*0.2f); nvgLineTo(g_nvg,rx,y); break;
        case 'V': nvgMoveTo(g_nvg,x,y); nvgLineTo(g_nvg,mx,by); nvgLineTo(g_nvg,rx,y); break;
        case 'W': nvgMoveTo(g_nvg,x,y); nvgLineTo(g_nvg,x+w*0.25f,by); nvgLineTo(g_nvg,mx,my); nvgLineTo(g_nvg,rx-w*0.25f,by); nvgLineTo(g_nvg,rx,y); break;
        case 'X': nvgMoveTo(g_nvg,x,y); nvgLineTo(g_nvg,rx,by); nvgMoveTo(g_nvg,rx,y); nvgLineTo(g_nvg,x,by); break;
        case 'Y': nvgMoveTo(g_nvg,x,y); nvgLineTo(g_nvg,mx,my); nvgLineTo(g_nvg,rx,y); nvgMoveTo(g_nvg,mx,my); nvgLineTo(g_nvg,mx,by); break;
        case 'Z': case '2': nvgMoveTo(g_nvg,x,y); nvgLineTo(g_nvg,rx,y); nvgLineTo(g_nvg,x,by); nvgLineTo(g_nvg,rx,by); break;
        case '1': nvgMoveTo(g_nvg,x+w*0.2f,y+h*0.2f); nvgLineTo(g_nvg,mx,y); nvgLineTo(g_nvg,mx,by); nvgMoveTo(g_nvg,x+w*0.2f,by); nvgLineTo(g_nvg,rx-w*0.2f,by); break;
        case '3': nvgMoveTo(g_nvg,x,y); nvgLineTo(g_nvg,rx,y); nvgLineTo(g_nvg,rx,by); nvgLineTo(g_nvg,x,by); nvgMoveTo(g_nvg,x+w*0.2f,my); nvgLineTo(g_nvg,rx,my); break;
        case '4': nvgMoveTo(g_nvg,x,y); nvgLineTo(g_nvg,x,my); nvgLineTo(g_nvg,rx,my); nvgMoveTo(g_nvg,rx-w*0.2f,y); nvgLineTo(g_nvg,rx-w*0.2f,by); break;
        case '6': nvgMoveTo(g_nvg,rx,y); nvgLineTo(g_nvg,x,y); nvgLineTo(g_nvg,x,by); nvgLineTo(g_nvg,rx,by); nvgLineTo(g_nvg,rx,my); nvgLineTo(g_nvg,x,my); break;
        case '7': nvgMoveTo(g_nvg,x,y); nvgLineTo(g_nvg,rx,y); nvgLineTo(g_nvg,mx,by); break;
        case '8': nvgRect(g_nvg,x,y,w,h); nvgMoveTo(g_nvg,x,my); nvgLineTo(g_nvg,rx,my); break;
        case '9': nvgMoveTo(g_nvg,rx,my); nvgLineTo(g_nvg,x,my); nvgLineTo(g_nvg,x,y); nvgLineTo(g_nvg,rx,y); nvgLineTo(g_nvg,rx,by); nvgLineTo(g_nvg,x,by); break;
        case '.': nvgRect(g_nvg,mx-0.8f,by-1.5f,1.6f,1.6f); break;
        case ':': nvgRect(g_nvg,mx-0.8f,y+h*0.25f,1.6f,1.6f); nvgRect(g_nvg,mx-0.8f,by-h*0.25f,1.6f,1.6f); break;
        case '-': nvgMoveTo(g_nvg,x+w*0.15f,my); nvgLineTo(g_nvg,rx-w*0.15f,my); break;
        case '(': nvgMoveTo(g_nvg,rx-w*0.2f,y); nvgLineTo(g_nvg,x+w*0.2f,my); nvgLineTo(g_nvg,rx-w*0.2f,by); break;
        case ')': nvgMoveTo(g_nvg,x+w*0.2f,y); nvgLineTo(g_nvg,rx-w*0.2f,my); nvgLineTo(g_nvg,x+w*0.2f,by); break;
        case '%': nvgMoveTo(g_nvg,x,by); nvgLineTo(g_nvg,rx,y); nvgCircle(g_nvg,x+w*0.2f,y+h*0.2f,1.2f); nvgCircle(g_nvg,rx-w*0.2f,by-h*0.2f,1.2f); break;
        default: break;
    }
}

static void draw_vector_text(const char* str, float cx, float cy, float char_w, float char_h, NVGcolor color, int align_center) {
    int len = (int)strlen(str);
    if (len <= 0) return;
    float pitch = char_w * 1.42f;
    float total_w = len * pitch - (pitch - char_w);
    float start_x = align_center ? (cx - total_w * 0.5f) : cx;
    float start_y = cy - char_h * 0.5f;

    nvgBeginPath(g_nvg);
    for (int i = 0; i < len; i++) {
        if (str[i] != ' ') {
            draw_glyph(str[i], start_x + i * pitch, start_y, char_w, char_h);
        }
    }
    nvgStrokeWidth(g_nvg, 1.45f);
    nvgLineCap(g_nvg, NVG_ROUND);
    nvgLineJoin(g_nvg, NVG_ROUND);
    nvgStrokeColor(g_nvg, color);
    nvgStroke(g_nvg);
}

// ============================================================================
// 4. 4-FINGER MULTI-TOUCH & MOUSE ENGINE
// ============================================================================
EMSCRIPTEN_KEEPALIVE
void synth_pointer_down(int pointer_id, float x, float y) {
    int hit_param = -1;
    for (int i = 0; i < NUM_PARAMS; i++) {
        SynthParam* p = &g_params[i];
        if (x >= p->bbox_x && x <= (p->bbox_x + p->bbox_w) &&
            y >= p->bbox_y && y <= (p->bbox_y + p->bbox_h)) {
            hit_param = i;
            break;
        }
    }

    if (hit_param < 0) {
        // Tapping/dragging inside the Oscilloscope plucks the Sitar & bends pitch (Meend)!
        Clay_ElementData scope = Clay_GetElementData(CLAY_ID("ScopeBox"));
        if (scope.found && x >= scope.boundingBox.x && x <= (scope.boundingBox.x + scope.boundingBox.width)) {
            float norm_x = clampf((x - scope.boundingBox.x) / scope.boundingBox.width, 0.0f, 1.0f);
            synth_trigger_pluck(0.95f, 1.0f + norm_x);
        }
        return;
    }

    if (g_pluck_env < 0.25f) synth_trigger_pluck(0.45f, 1.0f);

    for (int s = 0; s < MAX_TOUCH_POINTS; s++) {
        if (!g_touches[s].active || g_touches[s].pointer_id == pointer_id) {
            g_touches[s].active      = 1;
            g_touches[s].pointer_id  = pointer_id;
            g_touches[s].param_index = hit_param;
            g_touches[s].start_x     = x;
            g_touches[s].start_y     = y;
            g_touches[s].start_val   = g_params[hit_param].value;

            SynthParam* p = &g_params[hit_param];
            if (p->is_slider && p->bbox_w > 80.0f) {
                float track_x = p->bbox_x + 84.0f;
                float track_w = p->bbox_w - 138.0f;
                float norm = clampf((x - track_x) / track_w, 0.0f, 1.0f);
                p->value = p->min_val + norm * (p->max_val - p->min_val);
                js_emit_param(p->key, p->value);
            }
            break;
        }
    }
}

EMSCRIPTEN_KEEPALIVE
void synth_pointer_move(int pointer_id, float x, float y) {
    g_last_mouse_x = x;
    g_last_mouse_y = y;
    for (int s = 0; s < MAX_TOUCH_POINTS; s++) {
        if (g_touches[s].active && g_touches[s].pointer_id == pointer_id) {
            SynthParam* p = &g_params[g_touches[s].param_index];
            float range = p->max_val - p->min_val;

            if (p->is_slider && p->bbox_w > 80.0f) {
                float track_x = p->bbox_x + 84.0f;
                float track_w = p->bbox_w - 138.0f;
                float norm = clampf((x - track_x) / track_w, 0.0f, 1.0f);
                p->value = p->min_val + norm * range;
            } else {
                float dy = (g_touches[s].start_y - y) / 110.0f;
                float dx = (x - g_touches[s].start_x) / 180.0f;
                p->value = clampf(g_touches[s].start_val + (dy + dx) * range, p->min_val, p->max_val);
            }
            js_emit_param(p->key, p->value);
            break;
        }
    }
}

EMSCRIPTEN_KEEPALIVE
void synth_pointer_up(int pointer_id) {
    for (int s = 0; s < MAX_TOUCH_POINTS; s++) {
        if (g_touches[s].active && g_touches[s].pointer_id == pointer_id) {
            g_touches[s].active = 0;
        }
    }
}

EMSCRIPTEN_KEEPALIVE
void imgui_on_mouse_move(float x, float y) { synth_pointer_move(0, x, y); }

EMSCRIPTEN_KEEPALIVE
void imgui_on_mouse_button(int button, int down) {
    (void)button;
    if (down) synth_pointer_down(0, g_last_mouse_x, g_last_mouse_y);
    else      synth_pointer_up(0);
}

EMSCRIPTEN_KEEPALIVE
void imgui_on_mouse_wheel(float dx, float dy) {
    (void)dx;
    for (int i = 0; i < NUM_PARAMS; i++) {
        SynthParam* p = &g_params[i];
        if (g_last_mouse_x >= p->bbox_x && g_last_mouse_x <= (p->bbox_x + p->bbox_w) &&
            g_last_mouse_y >= p->bbox_y && g_last_mouse_y <= (p->bbox_y + p->bbox_h)) {
            float range = p->max_val - p->min_val;
            p->value = clampf(p->value + dy * 0.05f * range, p->min_val, p->max_val);
            js_emit_param(p->key, p->value);
            break;
        }
    }
}

// ============================================================================
// 5. IMGUI-KNOBS (`ImGuiKnobVariant_WiperDot`) & IMPLOT VISUAL RECREATION!
// ============================================================================
static void draw_imgui_wiperdot_knob(SynthParam* p, int is_touched) {
    float cx = p->bbox_x + p->bbox_w * 0.5f;
    float cy = p->bbox_y + p->bbox_h * 0.50f;
    float radius = fminf(p->bbox_w * 0.42f, (p->bbox_h - 34.0f) * 0.46f);
    if (radius < 14.0f) radius = 14.0f;

    draw_vector_text(p->name, cx, p->bbox_y + 9.0f, 4.6f, 7.2f, g_col_text, 1);

    float norm = (p->value - p->min_val) / (p->max_val - p->min_val);
    float a0 = 0.75f * (float)M_PI;
    float a1 = 2.25f * (float)M_PI;
    float a_val = a0 + norm * (a1 - a0);

    nvgBeginPath(g_nvg);
    nvgArc(g_nvg, cx, cy, radius, a0, a1, NVG_CW);
    nvgStrokeWidth(g_nvg, radius * 0.18f);
    nvgStrokeColor(g_nvg, g_col_panel);
    nvgLineCap(g_nvg, NVG_ROUND);
    nvgStroke(g_nvg);

    if (norm > 0.005f) {
        nvgBeginPath(g_nvg);
        nvgArc(g_nvg, cx, cy, radius, a0, a_val, NVG_CW);
        nvgStrokeWidth(g_nvg, radius * (is_touched ? 0.22f : 0.18f));
        nvgStrokeColor(g_nvg, is_touched ? g_col_alert : g_col_accent);
        nvgLineCap(g_nvg, NVG_ROUND);
        nvgStroke(g_nvg);
    }

    float body_r = radius * 0.74f;
    NVGpaint knob_grad = nvgLinearGradient(g_nvg, cx, cy - body_r, cx, cy + body_r, g_col_panel, g_col_canvas);
    nvgBeginPath(g_nvg);
    nvgCircle(g_nvg, cx, cy, body_r);
    nvgFillPaint(g_nvg, knob_grad);
    nvgFill(g_nvg);
    nvgStrokeWidth(g_nvg, 1.2f);
    nvgStrokeColor(g_nvg, is_touched ? g_col_accent : hex_to_nvg(g_hex_text, 0.15f));
    nvgStroke(g_nvg);

    float dot_r = body_r * 0.65f;
    float dx = cx + cosf(a_val) * dot_r;
    float dy = cy + sinf(a_val) * dot_r;
    nvgBeginPath(g_nvg);
    nvgCircle(g_nvg, dx, dy, radius * 0.11f);
    nvgFillColor(g_nvg, is_touched ? g_col_alert : g_col_text);
    nvgFill(g_nvg);

    char val_buf[24];
    snprintf(val_buf, sizeof(val_buf), p->fmt, p->value);
    float pill_w = fminf(p->bbox_w - 6.0f, 54.0f);
    float pill_y = p->bbox_y + p->bbox_h - 15.0f;
    nvgBeginPath(g_nvg);
    nvgRoundedRect(g_nvg, cx - pill_w * 0.5f, pill_y, pill_w, 14.0f, 3.0f);
    nvgFillColor(g_nvg, g_col_panel);
    nvgFill(g_nvg);
    draw_vector_text(val_buf, cx, pill_y + 7.0f, 4.4f, 6.8f, is_touched ? g_col_alert : g_col_accent, 1);
}

static void draw_imgui_slider(SynthParam* p, int is_touched) {
    nvgBeginPath(g_nvg);
    nvgRoundedRect(g_nvg, p->bbox_x, p->bbox_y, p->bbox_w, p->bbox_h, 5.0f);
    nvgFillColor(g_nvg, g_col_panel);
    nvgFill(g_nvg);

    float cy = p->bbox_y + p->bbox_h * 0.5f;
    draw_vector_text(p->name, p->bbox_x + 8.0f, cy, 4.6f, 7.2f, g_col_text, 0);

    float track_x = p->bbox_x + 84.0f;
    float track_w = fmaxf(20.0f, p->bbox_w - 138.0f);
    float norm = (p->value - p->min_val) / (p->max_val - p->min_val);
    float fill_w = norm * track_w;

    nvgBeginPath(g_nvg);
    nvgRoundedRect(g_nvg, track_x, cy - 5.0f, track_w, 10.0f, 4.0f);
    nvgFillColor(g_nvg, g_col_canvas);
    nvgFill(g_nvg);

    nvgBeginPath(g_nvg);
    nvgRoundedRect(g_nvg, track_x, cy - 5.0f, fill_w, 10.0f, 4.0f);
    nvgFillColor(g_nvg, is_touched ? g_col_alert : g_col_accent);
    nvgFill(g_nvg);

    nvgBeginPath(g_nvg);
    nvgRoundedRect(g_nvg, track_x + fill_w - 5.0f, cy - 7.5f, 10.0f, 15.0f, 3.0f);
    nvgFillColor(g_nvg, g_col_text);
    nvgFill(g_nvg);

    char val_buf[24];
    snprintf(val_buf, sizeof(val_buf), "%.0f%%", norm * 100.0f);
    draw_vector_text(val_buf, p->bbox_x + p->bbox_w - 26.0f, cy, 4.5f, 7.0f, g_col_accent, 1);
}

static void draw_implot_oscilloscope(float x, float y, float w, float h) {
    nvgBeginPath(g_nvg);
    nvgRoundedRect(g_nvg, x, y, w, h, 6.0f);
    nvgFillColor(g_nvg, g_col_canvas);
    nvgFill(g_nvg);
    nvgStrokeWidth(g_nvg, 1.0f);
    nvgStrokeColor(g_nvg, g_col_panel);
    nvgStroke(g_nvg);

    nvgBeginPath(g_nvg);
    for (int gx = 1; gx < 6; gx++) {
        float lx = x + (w * gx) / 6.0f;
        nvgMoveTo(g_nvg, lx, y);
        nvgLineTo(g_nvg, lx, y + h);
    }
    for (int gy = 1; gy < 4; gy++) {
        float ly = y + (h * gy) / 4.0f;
        nvgMoveTo(g_nvg, x, ly);
        nvgLineTo(g_nvg, x + w, ly);
    }
    nvgStrokeWidth(g_nvg, 1.0f);
    nvgStrokeColor(g_nvg, hex_to_nvg(g_hex_accent, 0.14f));
    nvgStroke(g_nvg);

    float root_hz = g_params[0].value * g_meend_ratio;
    float jawari  = g_params[1].value;
    float res     = g_params[2].value;
    float drive   = g_params[3].value;
    float morph   = g_params[4].value;

    g_phase += 0.045f;
    float mid_y = y + h * 0.52f;
    float amp_h = h * 0.38f;

    nvgBeginPath(g_nvg);
    nvgMoveTo(g_nvg, x, mid_y);
    for (int i = 0; i < SCOPE_POINTS; i++) {
        float t = (float)i / (float)(SCOPE_POINTS - 1);
        float px = x + t * w;
        float env = sinf(t * (float)M_PI);
        float sa = sinf(2.0f * (float)M_PI * (root_hz * 0.025f) * t + g_phase);
        float buzz = jawari * sinf(2.0f * (float)M_PI * (root_hz * 0.075f) * t * (1.0f + 0.25f * sa)) * env;
        nvgLineTo(g_nvg, px, mid_y - buzz * amp_h);
    }
    nvgLineTo(g_nvg, x + w, mid_y);
    nvgClosePath(g_nvg);
    nvgFillColor(g_nvg, hex_to_nvg(g_hex_alert, 0.22f));
    nvgFill(g_nvg);

    nvgBeginPath(g_nvg);
    for (int i = 0; i < SCOPE_POINTS; i++) {
        float t = (float)i / (float)(SCOPE_POINTS - 1);
        float px = x + t * w;
        float env = sinf(t * (float)M_PI);
        float sa = sinf(2.0f * (float)M_PI * (root_hz * 0.025f) * t + g_phase);
        float buzz = jawari * sinf(2.0f * (float)M_PI * (root_hz * 0.075f) * t * (1.0f + 0.25f * sa)) * env;
        float py = mid_y - buzz * amp_h;
        if (i == 0) nvgMoveTo(g_nvg, px, py);
        else nvgLineTo(g_nvg, px, py);
    }
    nvgStrokeWidth(g_nvg, 1.5f);
    nvgStrokeColor(g_nvg, g_col_alert);
    nvgStroke(g_nvg);

    nvgBeginPath(g_nvg);
    for (int i = 0; i < SCOPE_POINTS; i++) {
        float t = (float)i / (float)(SCOPE_POINTS - 1);
        float px = x + t * w;
        float env = sinf(t * (float)M_PI);
        float f = root_hz * 0.025f;

        float sa = sinf(2.0f * (float)M_PI * f * t + g_phase);
        float pa = res * 0.55f * sinf(2.0f * (float)M_PI * (f * 1.5f) * t - g_phase * 0.5f);
        float jw = jawari * sinf(2.0f * (float)M_PI * (f * (2.5f + morph)) * t * (1.0f + 0.25f * sa));

        float raw = (sa + pa + jw) * env * drive;
        float sample = raw / (1.0f + 0.45f * fabsf(raw));
        float py = mid_y - sample * amp_h;

        if (i == 0) nvgMoveTo(g_nvg, px, py);
        else nvgLineTo(g_nvg, px, py);
    }
    nvgStrokeWidth(g_nvg, 2.5f);
    nvgStrokeColor(g_nvg, g_col_accent);
    nvgStroke(g_nvg);

    float leg_x = x + 10.0f, leg_y = y + 8.0f;
    nvgBeginPath(g_nvg);
    nvgRoundedRect(g_nvg, leg_x, leg_y, 156.0f, 32.0f, 4.0f);
    nvgFillColor(g_nvg, hex_to_nvg(0x090d16, 0.80f));
    nvgFill(g_nvg);

    nvgBeginPath(g_nvg);
    nvgRect(g_nvg, leg_x + 7.0f, leg_y + 6.0f, 8.0f, 8.0f);
    nvgFillColor(g_nvg, g_col_accent);
    nvgFill(g_nvg);
    draw_vector_text("MASTER SITAR WAVE", leg_x + 20.0f, leg_y + 10.0f, 4.0f, 6.0f, g_col_text, 0);

    nvgBeginPath(g_nvg);
    nvgRect(g_nvg, leg_x + 7.0f, leg_y + 18.0f, 8.0f, 8.0f);
    nvgFillColor(g_nvg, g_col_alert);
    nvgFill(g_nvg);
    draw_vector_text("JAWARI HARMONICS", leg_x + 20.0f, leg_y + 22.0f, 4.0f, 6.0f, g_col_muted, 0);
}

// ============================================================================
// 6. CLAY FLEXBOX LAYOUT + NANOVG RENDER LOOP
// ============================================================================
static void render_frame(void) {
    if (!g_nvg) return;

    double css_w = 0, css_h = 0;
    if (emscripten_get_element_css_size(g_canvas_sel, &css_w, &css_h) == EMSCRIPTEN_RESULT_SUCCESS && css_w > 50 && css_h > 50) {
        g_css_w = (float)css_w;
        g_css_h = (float)css_h;
    }

    int fb_w = 0, fb_h = 0;
    emscripten_webgl_get_drawing_buffer_size(g_gl, &fb_w, &fb_h);
    float dpr = (g_css_w > 0 && fb_w > 0) ? ((float)fb_w / g_css_w) : 1.0f;

    glViewport(0, 0, fb_w, fb_h);
    glClearColor(0.0f, 0.0f, 0.0f, 0.0f);
    glClear(GL_COLOR_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);

    Clay_SetLayoutDimensions((Clay_Dimensions){ g_css_w, g_css_h });
    Clay_BeginLayout();

    int is_mobile_narrow = (g_css_w < 600.0f);
    Clay_LayoutDirection root_dir = is_mobile_narrow ? CLAY_TOP_TO_BOTTOM : CLAY_LEFT_TO_RIGHT;

    CLAY(CLAY_ID("RootContainer"), {
        .layout = {
            .sizing = { CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0) },
            .layoutDirection = root_dir,
            .padding = { 10, 10, 10, 10 },
            .childGap = 12
        }
    }) {
        CLAY(CLAY_ID("ControlsRack"), {
            .layout = {
                .sizing = {
                    is_mobile_narrow ? CLAY_SIZING_GROW(0) : CLAY_SIZING_FIXED(340),
                    is_mobile_narrow ? CLAY_SIZING_FIXED(145) : CLAY_SIZING_GROW(0)
                },
                .layoutDirection = CLAY_TOP_TO_BOTTOM,
                .padding = { 10, 10, 24, 10 },
                .childGap = 8
            }
        }) {
            CLAY(CLAY_ID("KnobRow"), {
                .layout = {
                    .sizing = { CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0) },
                    .layoutDirection = CLAY_LEFT_TO_RIGHT,
                    .childGap = 6
                }
            }) {
                for (int i = 0; i < 4; i++) {
                    CLAY(CLAY_IDI("ParamBox", i), {
                        .layout = { .sizing = { CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0) } }
                    }) {}
                }
            }
            CLAY(CLAY_IDI("ParamBox", 4), {
                .layout = { .sizing = { CLAY_SIZING_GROW(0), CLAY_SIZING_FIXED(28) } }
            }) {}
        }

        CLAY(CLAY_ID("ScopeBox"), {
            .layout = { .sizing = { CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0) } }
        }) {}
    }

    Clay_EndLayout(0.016f);

    nvgBeginFrame(g_nvg, g_css_w, g_css_h, dpr);

    nvgBeginPath(g_nvg);
    nvgRoundedRect(g_nvg, 0, 0, g_css_w, g_css_h, 8.0f);
    nvgFillColor(g_nvg, g_col_surface);
    nvgFill(g_nvg);

    Clay_ElementData rack_data = Clay_GetElementData(CLAY_ID("ControlsRack"));
    if (rack_data.found) {
        nvgBeginPath(g_nvg);
        nvgRoundedRect(g_nvg, rack_data.boundingBox.x, rack_data.boundingBox.y, rack_data.boundingBox.width, rack_data.boundingBox.height, 6.0f);
        nvgFillColor(g_nvg, g_col_canvas);
        nvgFill(g_nvg);
        nvgStrokeWidth(g_nvg, 1.0f);
        nvgStrokeColor(g_nvg, g_col_panel);
        nvgStroke(g_nvg);

        draw_vector_text("SAANSKARA RAGA DSP RACK (4-TOUCH)", rack_data.boundingBox.x + 10.0f, rack_data.boundingBox.y + 12.0f, 4.5f, 7.0f, g_col_muted, 0);
    }

    for (int i = 0; i < NUM_PARAMS; i++) {
        Clay_ElementData data = Clay_GetElementData(CLAY_IDI("ParamBox", i));
        if (data.found) {
            SynthParam* p = &g_params[i];
            p->bbox_x = data.boundingBox.x;
            p->bbox_y = data.boundingBox.y;
            p->bbox_w = data.boundingBox.width;
            p->bbox_h = data.boundingBox.height;

            int touched = 0;
            for (int s = 0; s < MAX_TOUCH_POINTS; s++) {
                if (g_touches[s].active && g_touches[s].param_index == i) touched = 1;
            }

            if (p->is_slider) draw_imgui_slider(p, touched);
            else              draw_imgui_wiperdot_knob(p, touched);
        }
    }

    Clay_ElementData scope_data = Clay_GetElementData(CLAY_ID("ScopeBox"));
    if (scope_data.found) {
        draw_implot_oscilloscope(
            scope_data.boundingBox.x, scope_data.boundingBox.y,
            scope_data.boundingBox.width, scope_data.boundingBox.height
        );
    }

    nvgEndFrame(g_nvg);
}

// ============================================================================
// 7. NATIVE C TOUCH & INITIALIZATION
// ============================================================================
static EM_BOOL on_c_touchstart(int eventType, const EmscriptenTouchEvent* e, void* userData) {
    (void)eventType; (void)userData;
    for (int i = 0; i < e->numTouches; i++) {
        if (e->touches[i].isChanged) {
            synth_pointer_down((int)e->touches[i].identifier + 100, (float)e->touches[i].targetX, (float)e->touches[i].targetY);
        }
    }
    return EM_TRUE;
}

static EM_BOOL on_c_touchmove(int eventType, const EmscriptenTouchEvent* e, void* userData) {
    (void)eventType; (void)userData;
    for (int i = 0; i < e->numTouches; i++) {
        if (e->touches[i].isChanged) {
            synth_pointer_move((int)e->touches[i].identifier + 100, (float)e->touches[i].targetX, (float)e->touches[i].targetY);
        }
    }
    return EM_TRUE;
}

static EM_BOOL on_c_touchend(int eventType, const EmscriptenTouchEvent* e, void* userData) {
    (void)eventType; (void)userData;
    for (int i = 0; i < e->numTouches; i++) {
        if (e->touches[i].isChanged) {
            synth_pointer_up((int)e->touches[i].identifier + 100);
        }
    }
    return EM_TRUE;
}

EMSCRIPTEN_KEEPALIVE
void imgui_apply_raga_theme(uint32_t bg_canvas, uint32_t bg_surface, uint32_t bg_panel,
                            uint32_t accent_primary, uint32_t accent_alert, uint32_t text_main) {
    g_hex_accent  = accent_primary;
    g_hex_alert   = accent_alert;
    g_hex_text    = text_main;
    g_col_canvas  = hex_to_nvg(bg_canvas, 1.0f);
    g_col_surface = hex_to_nvg(bg_surface, 1.0f);
    g_col_panel   = hex_to_nvg(bg_panel, 1.0f);
    g_col_accent  = hex_to_nvg(accent_primary, 1.0f);
    g_col_alert   = hex_to_nvg(accent_alert, 1.0f);
    g_col_text    = hex_to_nvg(text_main, 1.0f);
    g_col_muted   = hex_to_nvg(text_main, 0.55f);
}

EMSCRIPTEN_KEEPALIVE
void imgui_set_canvas_size(int width, int height) {
    if (width > 50)  g_css_w = (float)width;
    if (height > 50) g_css_h = (float)height;
}

static void handle_clay_error(Clay_ErrorData errorData) {
    printf("[Clay] %s\n", errorData.errorText.chars);
}

EMSCRIPTEN_KEEPALIVE
int init_saanskara_imgui(const char* canvas_selector) {
    snprintf(g_canvas_sel, sizeof(g_canvas_sel), "%s", canvas_selector);

    EmscriptenWebGLContextAttributes attrs;
    emscripten_webgl_init_context_attributes(&attrs);
    attrs.majorVersion = 2;
    attrs.stencil = 1;
    attrs.antialias = 1;

    g_gl = emscripten_webgl_create_context(canvas_selector, &attrs);
    if (g_gl <= 0) return -1;
    emscripten_webgl_make_context_current(g_gl);

    g_nvg = nvgCreateGLES3(NVG_ANTIALIAS | NVG_STENCIL_STROKES);

    Clay_SetMaxElementCount(256);
    uint32_t min_mem = Clay_MinMemorySize();
    void* clay_mem = malloc(min_mem);
    Clay_Arena arena = Clay_CreateArenaWithCapacityAndMemory(min_mem, clay_mem);
    Clay_Initialize(arena, (Clay_Dimensions){ g_css_w, g_css_h }, (Clay_ErrorHandler){ handle_clay_error });

    emscripten_set_touchstart_callback(canvas_selector, NULL, EM_TRUE, on_c_touchstart);
    emscripten_set_touchmove_callback(canvas_selector,  NULL, EM_TRUE, on_c_touchmove);
    emscripten_set_touchend_callback(canvas_selector,   NULL, EM_TRUE, on_c_touchend);
    emscripten_set_touchcancel_callback(canvas_selector,NULL, EM_TRUE, on_c_touchend);

    imgui_apply_raga_theme(0x090d16, 0x111827, 0x1e293b, 0xf59e0b, 0xe11d48, 0xf8fafc);
    emscripten_set_main_loop(render_frame, 0, 0);
    return 0;
}