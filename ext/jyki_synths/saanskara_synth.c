// ext/jyki_synths/saanskara_synth.c
// Pure C99 Multi-Touch Synth & 120fps Oscilloscope powered by Clay (clay.h) + NanoVG (WebGL2)

#define CLAY_IMPLEMENTATION
#include "clay.h"

#include <GLES3/gl3.h>
#include <emscripten.h>
#include <emscripten/html5.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define NANOVG_GLES3_IMPLEMENTATION
#include "nanovg.h"
#include "nanovg_gl.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846f
#endif

#define MAX_TOUCH_POINTS 10
#define NUM_PARAMS 5
#define SCOPE_POINTS 256

typedef struct {
    const char* name;
    const char* key;
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
    { "SA (ROOT)", "root_hz",      240.0f, 110.0f, 440.0f, 0, 0,0,0,0 },
    { "JAWARI",    "jawari_buzz",  0.45f,  0.0f,   1.0f,   0, 0,0,0,0 },
    { "TARAB RES", "resonance",    0.68f,  0.0f,   1.0f,   0, 0,0,0,0 },
    { "TUBE DRIVE","analog_drive", 1.65f,  0.5f,   4.0f,   0, 0,0,0,0 },
    { "MORPH MIX", "morph_slider", 0.75f,  0.0f,   1.0f,   1, 0,0,0,0 }
};

static TouchSlot g_touches[MAX_TOUCH_POINTS];
static NVGcontext* g_nvg = NULL;
static EMSCRIPTEN_WEBGL_CONTEXT_HANDLE g_gl = 0;
static int g_width = 800, g_height = 240;
static float g_dpr = 1.0f;
static float g_phase = 0.0f;

static NVGcolor g_col_canvas, g_col_surface, g_col_panel, g_col_accent, g_col_alert, g_col_text;

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
    if (hit_param < 0) return;

    for (int s = 0; s < MAX_TOUCH_POINTS; s++) {
        if (!g_touches[s].active || g_touches[s].pointer_id == pointer_id) {
            g_touches[s].active      = 1;
            g_touches[s].pointer_id  = pointer_id;
            g_touches[s].param_index = hit_param;
            g_touches[s].start_x     = x;
            g_touches[s].start_y     = y;
            g_touches[s].start_val   = g_params[hit_param].value;

            SynthParam* p = &g_params[hit_param];
            if (p->is_slider && p->bbox_w > 24.0f) {
                float norm = clampf((x - (p->bbox_x + 12.0f)) / (p->bbox_w - 24.0f), 0.0f, 1.0f);
                p->value = p->min_val + norm * (p->max_val - p->min_val);
                js_emit_param(p->key, p->value);
            }
            break;
        }
    }
}

EMSCRIPTEN_KEEPALIVE
void synth_pointer_move(int pointer_id, float x, float y) {
    for (int s = 0; s < MAX_TOUCH_POINTS; s++) {
        if (g_touches[s].active && g_touches[s].pointer_id == pointer_id) {
            SynthParam* p = &g_params[g_touches[s].param_index];
            float range = p->max_val - p->min_val;

            if (p->is_slider && p->bbox_w > 24.0f) {
                float norm = clampf((x - (p->bbox_x + 12.0f)) / (p->bbox_w - 24.0f), 0.0f, 1.0f);
                p->value = p->min_val + norm * range;
            } else {
                float dy = (g_touches[s].start_y - y) / 120.0f;
                float dx = (x - g_touches[s].start_x) / 200.0f;
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

static void draw_nanovg_knob(SynthParam* p, int is_touched) {
    // Subtle card behind each knob so hit zone is clearly visible
    nvgBeginPath(g_nvg);
    nvgRoundedRect(g_nvg, p->bbox_x, p->bbox_y, p->bbox_w, p->bbox_h, 6.0f);
    nvgFillColor(g_nvg, g_col_canvas);
    nvgFill(g_nvg);

    float cx = p->bbox_x + p->bbox_w * 0.5f;
    float cy = p->bbox_y + p->bbox_h * 0.52f;
    float radius = fminf(p->bbox_w, p->bbox_h) * 0.34f;

    float norm = (p->value - p->min_val) / (p->max_val - p->min_val);
    float a0 = 0.75f * (float)M_PI;
    float a1 = 2.25f * (float)M_PI;
    float a_val = a0 + norm * (a1 - a0);

    // Track ring
    nvgBeginPath(g_nvg);
    nvgArc(g_nvg, cx, cy, radius, a0, a1, NVG_CW);
    nvgStrokeWidth(g_nvg, 5.0f);
    nvgStrokeColor(g_nvg, g_col_panel);
    nvgLineCap(g_nvg, NVG_ROUND);
    nvgStroke(g_nvg);

    // Active value arc
    nvgBeginPath(g_nvg);
    nvgArc(g_nvg, cx, cy, radius, a0, a_val, NVG_CW);
    nvgStrokeWidth(g_nvg, is_touched ? 7.0f : 5.5f);
    nvgStrokeColor(g_nvg, is_touched ? g_col_alert : g_col_accent);
    nvgStroke(g_nvg);

    // Center cap
    nvgBeginPath(g_nvg);
    nvgCircle(g_nvg, cx, cy, radius * 0.70f);
    nvgFillColor(g_nvg, g_col_surface);
    nvgFill(g_nvg);

    // Wiper needle
    float ix = cx + cosf(a_val) * (radius * 0.55f);
    float iy = cy + sinf(a_val) * (radius * 0.55f);
    nvgBeginPath(g_nvg);
    nvgMoveTo(g_nvg, cx, cy);
    nvgLineTo(g_nvg, ix, iy);
    nvgStrokeWidth(g_nvg, 2.5f);
    nvgStrokeColor(g_nvg, g_col_text);
    nvgStroke(g_nvg);
}

static void draw_nanovg_slider(SynthParam* p, int is_touched) {
    nvgBeginPath(g_nvg);
    nvgRoundedRect(g_nvg, p->bbox_x, p->bbox_y, p->bbox_w, p->bbox_h, 6.0f);
    nvgFillColor(g_nvg, g_col_canvas);
    nvgFill(g_nvg);

    float pad = 14.0f;
    float track_x = p->bbox_x + pad;
    float track_w = fmaxf(10.0f, p->bbox_w - pad * 2.0f);
    float track_y = p->bbox_y + p->bbox_h * 0.5f;
    float norm = (p->value - p->min_val) / (p->max_val - p->min_val);
    float fill_w = norm * track_w;

    nvgBeginPath(g_nvg);
    nvgRoundedRect(g_nvg, track_x, track_y - 4.0f, track_w, 8.0f, 4.0f);
    nvgFillColor(g_nvg, g_col_panel);
    nvgFill(g_nvg);

    nvgBeginPath(g_nvg);
    nvgRoundedRect(g_nvg, track_x, track_y - 4.0f, fill_w, 8.0f, 4.0f);
    nvgFillColor(g_nvg, is_touched ? g_col_alert : g_col_accent);
    nvgFill(g_nvg);

    nvgBeginPath(g_nvg);
    nvgCircle(g_nvg, track_x + fill_w, track_y, is_touched ? 10.5f : 8.0f);
    nvgFillColor(g_nvg, g_col_text);
    nvgFill(g_nvg);
}

static void draw_nanovg_oscilloscope(float x, float y, float w, float h) {
    nvgBeginPath(g_nvg);
    nvgRoundedRect(g_nvg, x, y, w, h, 8.0f);
    nvgFillColor(g_nvg, g_col_canvas);
    nvgFill(g_nvg);

    float root_hz = g_params[0].value;
    float jawari  = g_params[1].value;
    float res     = g_params[2].value;
    float drive   = g_params[3].value;
    float morph   = g_params[4].value;

    g_phase += 0.05f;
    float mid_y = y + h * 0.5f;
    float amp_h = h * 0.38f;

    // 1. Harmonic Overtone Trace
    nvgBeginPath(g_nvg);
    for (int i = 0; i < SCOPE_POINTS; i++) {
        float t = (float)i / (float)(SCOPE_POINTS - 1);
        float px = x + t * w;
        float env = sinf(t * (float)M_PI);
        float buzz = jawari * sinf(2.0f * (float)M_PI * (root_hz * 0.06f) * t + g_phase * 1.5f) * env;
        float py = mid_y - buzz * amp_h;
        if (i == 0) nvgMoveTo(g_nvg, px, py);
        else nvgLineTo(g_nvg, px, py);
    }
    nvgStrokeWidth(g_nvg, 1.5f);
    nvgStrokeColor(g_nvg, g_col_alert);
    nvgStroke(g_nvg);

    // 2. Primary Analog-Saturated Sitar Wave
    nvgBeginPath(g_nvg);
    for (int i = 0; i < SCOPE_POINTS; i++) {
        float t = (float)i / (float)(SCOPE_POINTS - 1);
        float px = x + t * w;
        float env = sinf(t * (float)M_PI);
        float f = root_hz * 0.022f;

        float sa = sinf(2.0f * (float)M_PI * f * t + g_phase);
        float pa = res * 0.6f * sinf(2.0f * (float)M_PI * (f * 1.5f) * t - g_phase * 0.5f);
        float jw = jawari * sinf(2.0f * (float)M_PI * (f * (2.5f + morph)) * t * (1.0f + 0.3f * sa));

        float raw = (sa + pa + jw) * env * drive;
        float sample = raw / (1.0f + 0.45f * fabsf(raw));
        float py = mid_y - sample * amp_h;

        if (i == 0) nvgMoveTo(g_nvg, px, py);
        else nvgLineTo(g_nvg, px, py);
    }
    nvgStrokeWidth(g_nvg, 2.6f);
    nvgStrokeColor(g_nvg, g_col_accent);
    nvgStroke(g_nvg);
}

static void render_frame(void) {
    if (!g_nvg) return;

    glViewport(0, 0, (int)(g_width * g_dpr), (int)(g_height * g_dpr));
    glClearColor(0.0f, 0.0f, 0.0f, 0.0f);
    glClear(GL_COLOR_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);

    Clay_SetLayoutDimensions((Clay_Dimensions){ (float)g_width, (float)g_height });
    Clay_BeginLayout();

    int is_mobile_narrow = (g_width < 600);
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
                    is_mobile_narrow ? CLAY_SIZING_FIXED(125) : CLAY_SIZING_GROW(0)
                },
                .layoutDirection = CLAY_TOP_TO_BOTTOM,
                .childGap = 8
            }
        }) {
            CLAY(CLAY_ID("KnobRow"), {
                .layout = {
                    .sizing = { CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0) },
                    .layoutDirection = CLAY_LEFT_TO_RIGHT,
                    .childGap = 8
                }
            }) {
                for (int i = 0; i < 4; i++) {
                    CLAY(CLAY_IDI("ParamBox", i), {
                        .layout = { .sizing = { CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0) } }
                    }) {}
                }
            }
            CLAY(CLAY_IDI("ParamBox", 4), {
                .layout = { .sizing = { CLAY_SIZING_GROW(0), CLAY_SIZING_FIXED(34) } }
            }) {}
        }

        CLAY(CLAY_ID("ScopeBox"), {
            .layout = { .sizing = { CLAY_SIZING_GROW(0), CLAY_SIZING_GROW(0) } }
        }) {}
    }

    Clay_EndLayout(0.016f);

    nvgBeginFrame(g_nvg, (float)g_width, (float)g_height, g_dpr);

    nvgBeginPath(g_nvg);
    nvgRoundedRect(g_nvg, 0, 0, (float)g_width, (float)g_height, 8.0f);
    nvgFillColor(g_nvg, g_col_surface);
    nvgFill(g_nvg);

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

            if (p->is_slider) draw_nanovg_slider(p, touched);
            else              draw_nanovg_knob(p, touched);
        }
    }

    Clay_ElementData scope_data = Clay_GetElementData(CLAY_ID("ScopeBox"));
    if (scope_data.found) {
        draw_nanovg_oscilloscope(
            scope_data.boundingBox.x, scope_data.boundingBox.y,
            scope_data.boundingBox.width, scope_data.boundingBox.height
        );
    }

    nvgEndFrame(g_nvg);
}

EMSCRIPTEN_KEEPALIVE
void imgui_apply_raga_theme(uint32_t bg_canvas, uint32_t bg_surface, uint32_t bg_panel,
                            uint32_t accent_primary, uint32_t accent_alert, uint32_t text_main) {
    g_col_canvas  = hex_to_nvg(bg_canvas, 1.0f);
    g_col_surface = hex_to_nvg(bg_surface, 1.0f);
    g_col_panel   = hex_to_nvg(bg_panel, 1.0f);
    g_col_accent  = hex_to_nvg(accent_primary, 1.0f);
    g_col_alert   = hex_to_nvg(accent_alert, 1.0f);
    g_col_text    = hex_to_nvg(text_main, 1.0f);
}

EMSCRIPTEN_KEEPALIVE
void imgui_set_canvas_size(int width, int height, float dpr) {
    g_width  = width > 100 ? width : 800;
    g_height = height > 80 ? height : 220;
    g_dpr    = dpr > 0.5f ? dpr : 1.0f;
}

static void handle_clay_error(Clay_ErrorData errorData) {
    printf("[Clay] %s\n", errorData.errorText.chars);
}

EMSCRIPTEN_KEEPALIVE
int init_saanskara_imgui(const char* canvas_selector) {
    EmscriptenWebGLContextAttributes attrs;
    emscripten_webgl_init_context_attributes(&attrs);
    attrs.majorVersion = 2;
    attrs.stencil = 1;
    attrs.antialias = 1;

    g_gl = emscripten_webgl_create_context(canvas_selector, &attrs);
    if (g_gl <= 0) {
        printf("❌ Failed to create WebGL2 context on %s\n", canvas_selector);
        return -1;
    }
    emscripten_webgl_make_context_current(g_gl);

    g_nvg = nvgCreateGLES3(NVG_ANTIALIAS | NVG_STENCIL_STROKES);

    // CRITICAL FIX: Cap Clay max elements to 256 and allocate the EXACT size Clay_MinMemorySize() requests!
    Clay_SetMaxElementCount(256);
    uint32_t min_mem = Clay_MinMemorySize();
    void* clay_mem = malloc(min_mem);
    Clay_Arena arena = Clay_CreateArenaWithCapacityAndMemory(min_mem, clay_mem);
    Clay_Initialize(arena, (Clay_Dimensions){ (float)g_width, (float)g_height }, (Clay_ErrorHandler){ handle_clay_error });

    imgui_apply_raga_theme(0x090d16, 0x111827, 0x1e293b, 0xf59e0b, 0xe11d48, 0xf8fafc);
    emscripten_set_main_loop(render_frame, 0, 0);
    return 0;
}