// ext/native_host/jyki_native_host.c
// Pure C99 Native Desktop Host (GLFW + OpenGL 3 + miniaudio.h) wrapping saanskara_synth.c!
// Zero Electron • Zero WebView • Direct Hardware Audio + 120fps GPU Vector UI

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef __APPLE__
  #define GL_SILENCE_DEPRECATION
  #include <OpenGL/gl3.h>
#else
  #define GL_GLEXT_PROTOTYPES
  #include <GL/gl.h>
  #include <GL/glext.h>
#endif

#define GLFW_INCLUDE_NONE
#include <GLFW/glfw3.h>

// ============================================================================
// 1. SHIM EMSCRIPTEN MACROS SO `saanskara_synth.c` COMPILES NATIVELY AS-IS!
// ============================================================================
#define EMSCRIPTEN_KEEPALIVE
#define EM_BOOL int
#define EM_TRUE 1
#define EMSCRIPTEN_RESULT_SUCCESS 0
#define EMSCRIPTEN_WEBGL_CONTEXT_HANDLE int
#define EM_JS(ret, name, params, ...) static ret name params { (void)0; }

typedef struct { int majorVersion; int stencil; int antialias; } EmscriptenWebGLContextAttributes;
typedef struct { int identifier; int isChanged; double targetX; double targetY; } EmscriptenTouchPoint;
typedef struct { int numTouches; EmscriptenTouchPoint touches[10]; } EmscriptenTouchEvent;

static GLFWwindow* g_glfw_win = NULL;

static double emscripten_get_now(void) {
    return glfwGetTime() * 1000.0;
}

static int emscripten_get_element_css_size(const char* sel, double* w, double* h) {
    (void)sel;
    if (!g_glfw_win) return -1;
    int ww = 800, wh = 260;
    glfwGetWindowSize(g_glfw_win, &ww, &wh);
    *w = (double)ww;
    *h = (double)wh;
    return EMSCRIPTEN_RESULT_SUCCESS;
}

static void emscripten_webgl_get_drawing_buffer_size(int ctx, int* w, int* h) {
    (void)ctx;
    if (!g_glfw_win) { *w = 800; *h = 260; return; }
    glfwGetFramebufferSize(g_glfw_win, w, h);
}

static void emscripten_webgl_init_context_attributes(EmscriptenWebGLContextAttributes* a) { (void)a; }
static int  emscripten_webgl_create_context(const char* s, EmscriptenWebGLContextAttributes* a) { (void)s; (void)a; return 1; }
static void emscripten_webgl_make_context_current(int c) { (void)c; }
static void emscripten_set_touchstart_callback(const char* s, void* u, int c, void* fn) { (void)s;(void)u;(void)c;(void)fn; }
static void emscripten_set_touchmove_callback(const char* s, void* u, int c, void* fn)  { (void)s;(void)u;(void)c;(void)fn; }
static void emscripten_set_touchend_callback(const char* s, void* u, int c, void* fn)   { (void)s;(void)u;(void)c;(void)fn; }
static void emscripten_set_touchcancel_callback(const char* s, void* u, int c, void* fn){ (void)s;(void)u;(void)c;(void)fn; }
static void emscripten_set_main_loop(void (*fn)(void), int fps, int sim) { (void)fn; (void)fps; (void)sim; }

// Map NanoVG GLES3 calls to Desktop OpenGL 3.2+ Core Profile!
#define NANOVG_GL3_IMPLEMENTATION
#define nvgCreateGLES3 nvgCreateGL3
#define nvgDeleteGLES3 nvgDeleteGL3

// Include our actual unmodified C99 Synth + Clay + NanoVG UI!
#include "../jyki_synths/saanskara_synth.c"

// ============================================================================
// 2. HARDWARE AUDIO ENGINE (`miniaudio.h` -> CoreAudio / ALSA / Pulse / WASAPI)
// ============================================================================
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

static ma_device g_audio_device;
static int g_audio_initialized = 0;
static int g_octave_shift = 0;

// Real-time hardware audio thread callback (48,000 Hz stereo float)
static void native_audio_callback(ma_device* pDevice, void* pOutput, const void* pInput, ma_uint32 frameCount) {
    (void)pDevice; (void)pInput;
    float* out = (float*)pOutput;

    if (g_is_stopped) {
        memset(out, 0, frameCount * 2 * sizeof(float));
        return;
    }

    // If synth_render_audio_block is present in saanskara_synth.c, use it; otherwise synthesize directly!
    float meend_ms = g_params[4].value;
    float target_hz = g_params[0].value * g_meend_target;
    float jawari    = g_params[1].value;
    float res       = g_params[2].value;
    float drive     = g_params[3].value;
    float morph     = g_params[5].value;
    float inv_sr    = 1.0f / g_audio_sample_rate;

    static float s_root_hz = 240.0f, s_lead_hz = 240.0f;
    static float p_drone = 0.0f, p_sub = 0.0f, p_pa = 0.0f, p_lead = 0.0f, p_jaw = 0.0f, p_lfo = 0.0f;

    float meend_coeff = (meend_ms <= 2.0f) ? 1.0f : (1.0f - expf(-1000.0f / (fmaxf(2.0f, meend_ms * 0.35f) * g_audio_sample_rate)));

    for (ma_uint32 i = 0; i < frameCount; i++) {
        s_root_hz += (g_params[0].value - s_root_hz) * 0.002f;
        s_lead_hz += (target_hz - s_lead_hz) * meend_coeff;

        g_pluck_env *= 0.99982f;
        g_tarab_env *= 0.99994f;

        p_lfo += 2.0f * (float)M_PI * 0.35f * inv_sr;
        if (p_lfo > 2.0f * (float)M_PI) p_lfo -= 2.0f * (float)M_PI;
        float breath = 0.85f + 0.15f * sinf(p_lfo);

        float drone_gain = g_drone_active ? (0.38f * breath) : 0.0f;
        float lead_gain  = (g_drone_active ? 0.25f : 0.0f) + g_pluck_env * 0.95f;

        p_drone += 2.0f * (float)M_PI * s_root_hz * inv_sr;
        p_sub   += 2.0f * (float)M_PI * (s_root_hz * 0.5f) * inv_sr;
        p_pa    += 2.0f * (float)M_PI * (s_root_hz * 1.4983f) * inv_sr;
        p_lead  += 2.0f * (float)M_PI * s_lead_hz * inv_sr;
        p_jaw   += 2.0f * (float)M_PI * (s_lead_hz * (2.0f + morph * 3.0f)) * inv_sr;

        if (p_drone > 2.0f * (float)M_PI) p_drone -= 2.0f * (float)M_PI;
        if (p_sub   > 2.0f * (float)M_PI) p_sub   -= 2.0f * (float)M_PI;
        if (p_pa    > 2.0f * (float)M_PI) p_pa    -= 2.0f * (float)M_PI;
        if (p_lead  > 2.0f * (float)M_PI) p_lead  -= 2.0f * (float)M_PI;
        if (p_jaw   > 2.0f * (float)M_PI) p_jaw   -= 2.0f * (float)M_PI;

        float drone_sa = sinf(p_drone);
        float sub      = sinf(p_sub) * (0.65f * (1.0f - morph * 0.6f));
        float pa       = sinf(p_pa)  * (res * 0.60f);
        float lead_sa  = sinf(p_lead);
        float tarab    = sinf(p_lead * 3.0f + 1.5f * pa) * (res * 0.45f * g_tarab_env);

        float dyn_jaw  = jawari * (1.0f + 0.65f * g_pluck_env);
        float buzz     = dyn_jaw * 0.90f * sinf(p_jaw + (1.0f + dyn_jaw * 3.5f) * lead_sa);

        float raw = ((drone_sa * 0.5f + sub + pa) * drone_gain + (lead_sa + buzz + tarab) * lead_gain) * drive;
        float sample = (raw / (1.0f + 0.50f * fabsf(raw))) * (0.20f + 0.25f * morph);

        out[i * 2 + 0] = sample; // Left Channel
        out[i * 2 + 1] = sample; // Right Channel
    }
}

// ============================================================================
// 3. NATIVE GLFW MOUSE, SCROLL & SWARA KEYBOARD CALLBACKS
// ============================================================================
static void glfw_cursor_pos_cb(GLFWwindow* win, double x, double y) {
    (void)win;
    synth_pointer_move(0, (float)x, (float)y);
}

static void glfw_mouse_btn_cb(GLFWwindow* win, int button, int action, int mods) {
    (void)mods;
    if (button != GLFW_MOUSE_BUTTON_LEFT) return;
    double x = 0, y = 0;
    glfwGetCursorPos(win, &x, &y);
    if (action == GLFW_PRESS) synth_pointer_down(0, (float)x, (float)y);
    else if (action == GLFW_RELEASE) synth_pointer_up(0);
}

static void glfw_scroll_cb(GLFWwindow* win, double dx, double dy) {
    (void)win;
    imgui_on_mouse_wheel((float)dx, (float)dy);
}

static void glfw_key_cb(GLFWwindow* win, int key, int scancode, int action, int mods) {
    (void)win; (void)scancode; (void)mods;
    if (action != GLFW_PRESS) return;

    if (key == GLFW_KEY_ESCAPE) { synth_stop_all(); return; }
    if (key == GLFW_KEY_SPACE)  { synth_set_drone_active(!g_drone_active); return; }
    if (key == GLFW_KEY_Z)      { if (g_octave_shift > -2) g_octave_shift--; return; }
    if (key == GLFW_KEY_X)      { if (g_octave_shift <  2) g_octave_shift++; return; }

    // Number keys 1 / 2 / 3 switch Raga Themes live in the Native Window!
    if (key == GLFW_KEY_1) { imgui_apply_raga_theme(0x090d16, 0x111827, 0x1e293b, 0xf59e0b, 0xe11d48, 0xf8fafc); return; } // Midnight Studio
    if (key == GLFW_KEY_2) { imgui_apply_raga_theme(0x1c100b, 0x2a1810, 0x3d2317, 0xfb923c, 0xf43f5e, 0xfff7ed); return; } // Saffron Dusk
    if (key == GLFW_KEY_3) { imgui_apply_raga_theme(0xf1f5f9, 0xffffff, 0xe2e8f0, 0x0284c7, 0xdc2626, 0x0f172a); return; } // Ottawa Frost

    // Map Piano Keys (A W S E D F T G Y H U J K) to Semitones from SA!
    int semi = -999;
    switch (key) {
        case GLFW_KEY_A: semi = 0;  break; // Sa
        case GLFW_KEY_W: semi = 1;  break; // komal re
        case GLFW_KEY_S: semi = 2;  break; // Re
        case GLFW_KEY_E: semi = 3;  break; // komal ga
        case GLFW_KEY_D: semi = 4;  break; // Ga
        case GLFW_KEY_F: semi = 5;  break; // Ma
        case GLFW_KEY_T: semi = 6;  break; // Tivra Ma
        case GLFW_KEY_G: semi = 7;  break; // Pa
        case GLFW_KEY_Y: semi = 8;  break; // komal dha
        case GLFW_KEY_H: semi = 9;  break; // Dha
        case GLFW_KEY_U: semi = 10; break; // komal ni
        case GLFW_KEY_J: semi = 11; break; // Ni
        case GLFW_KEY_K: semi = 12; break; // Sa'
        default: break;
    }

    if (semi != -999) {
        float total_semi = (float)(semi + g_octave_shift * 12);
        float ratio = powf(2.0f, total_semi / 12.0f);
        synth_trigger_pluck(0.95f, ratio);
    }
}

// ============================================================================
// 4. PUBLIC C-ABI EXPORTED TO RUBY (`Fiddle` in `bin/jyki-desktop`)
// ============================================================================
int jyki_native_init(const char* title, int width, int height) {
    if (!glfwInit()) {
        fprintf(stderr, "❌ [Jyki Native] Failed to initialize GLFW (check X11/Wayland/WSLg display)\n");
        return -1;
    }

    glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, 3);
    glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, 2);
    glfwWindowHint(GLFW_OPENGL_PROFILE, GLFW_OPENGL_CORE_PROFILE);
#ifdef __APPLE__
    glfwWindowHint(GLFW_OPENGL_FORWARD_COMPAT, GL_TRUE);
#endif
    glfwWindowHint(GLFW_SAMPLES, 4);

    g_glfw_win = glfwCreateWindow(width, height, title, NULL, NULL);
    if (!g_glfw_win) {
        fprintf(stderr, "❌ [Jyki Native] Failed to open native OpenGL 3.2 window\n");
        glfwTerminate();
        return -1;
    }

    glfwMakeContextCurrent(g_glfw_win);
    glfwSwapInterval(1); // 60Hz/120Hz VSync

    glfwSetCursorPosCallback(g_glfw_win, glfw_cursor_pos_cb);
    glfwSetMouseButtonCallback(g_glfw_win, glfw_mouse_btn_cb);
    glfwSetScrollCallback(g_glfw_win, glfw_scroll_cb);
    glfwSetKeyCallback(g_glfw_win, glfw_key_cb);

    g_css_w = (float)width;
    g_css_h = (float)height;
    init_saanskara_imgui("#native");

    // Start Native Hardware Audio (CoreAudio / ALSA / Pulse / WASAPI)
    ma_device_config cfg = ma_device_config_init(ma_device_type_playback);
    cfg.playback.format   = ma_format_f32;
    cfg.playback.channels = 2;
    cfg.sampleRate        = 48000;
    cfg.dataCallback      = native_audio_callback;

    if (ma_device_init(NULL, &cfg, &g_audio_device) == MA_SUCCESS) {
        g_audio_sample_rate = (float)g_audio_device.sampleRate;
        ma_device_start(&g_audio_device);
        g_audio_initialized = 1;
        printf("🔊 [Jyki Native Audio] Hardware stream active @ %u Hz (2ch float32)\n", g_audio_device.sampleRate);
    } else {
        fprintf(stderr, "⚠️  [Jyki Native Audio] No audio output device found — running visuals only\n");
    }

    return 0;
}

int jyki_native_step_frame(void) {
    if (!g_glfw_win || glfwWindowShouldClose(g_glfw_win)) return 0;
    glfwPollEvents();
    render_frame();
    glfwSwapBuffers(g_glfw_win);
    return 1;
}

void jyki_native_shutdown(void) {
    if (g_audio_initialized) {
        ma_device_uninit(&g_audio_device);
        g_audio_initialized = 0;
    }
    if (g_glfw_win) {
        glfwDestroyWindow(g_glfw_win);
        g_glfw_win = NULL;
    }
    glfwTerminate();
}