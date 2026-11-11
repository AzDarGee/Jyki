// ext/imgui_synth/saanskara_imgui_synth.cpp
// Saanskara Studio Rack: Dear ImGui + ImPlot + imgui-knobs (WebGL2 WASM + Native Ready)

#include <cmath>
#include <cstdio>
#include <emscripten.h>
#include <emscripten/html5.h>
#include <GLES3/gl3.h>

#include "imgui.h"
#include "imgui_impl_opengl3.h"
#include "implot.h"
#include "imgui-knobs.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846f
#endif

// ============================================================================
// 1. SYNTH & OSCILLOSCOPE STATE (Shared with WebAudio & Rails CRDTs)
// ============================================================================
struct SaanskaraSynthState {
    float root_hz      = 240.0f; // Sa (C4/B3 region)
    float jawari_buzz  = 0.42f;  // Sitar bridge harmonic buzz
    float resonance    = 0.68f;  // Sympathetic tarab strings
    float analog_drive = 1.65f;  // Tube saturation
    float phase        = 0.0f;

    static constexpr int SCOPE_POINTS = 512;
    float time_axis[SCOPE_POINTS];
    float wave_out[SCOPE_POINTS];
    float jawari_layer[SCOPE_POINTS];
};

static SaanskaraSynthState g_synth;
static EMSCRIPTEN_WEBGL_CONTEXT_HANDLE g_gl_ctx = 0;
static int g_canvas_w = 800;
static int g_canvas_h = 300;

// Callback into Rails Stimulus Controller when a knob edit finishes!
EM_JS(void, js_notify_knob_changed, (const char* param_name, float value), {
    if (window.saanskaraOnImGuiParamChanged) {
        window.saanskaraOnImGuiParamChanged(UTF8ToString(param_name), value);
    }
});

// ============================================================================
// 2. FAST C/C++ DSP WAVEFORM GENERATOR FOR SCOPE & AUDIO PREVIEW
// ============================================================================
static void compute_dsp_frame() {
    g_synth.phase += 0.045f;
    for (int i = 0; i < SaanskaraSynthState::SCOPE_POINTS; i++) {
        float t = (float)i / (float)SaanskaraSynthState::SCOPE_POINTS;
        g_synth.time_axis[i] = t * 10.0f; // 0..10ms window

        float env = std::sin(t * M_PI);
        float freq_scale = g_synth.root_hz * 0.025f;

        // Fundamental (Sa) + Fifth (Pa)
        float sa = std::sin(2.0f * M_PI * freq_scale * t + g_synth.phase);
        float pa = g_synth.resonance * 0.55f * std::sin(2.0f * M_PI * (freq_scale * 1.5f) * t - g_synth.phase * 0.5f);

        // Jawari bridge non-linear parabolic buzz modulation
        float buzz = g_synth.jawari_buzz * std::sin(2.0f * M_PI * (freq_scale * 3.0f) * t * (1.0f + 0.25f * sa));
        g_synth.jawari_layer[i] = buzz * env;

        // Combined signal through fast rational soft-clipper: x / (1 + |x|)
        float raw = (sa + pa + buzz) * env * g_synth.analog_drive;
        g_synth.wave_out[i] = raw / (1.0f + 0.45f * std::fabs(raw));
    }
}

// ============================================================================
// 3. RAGA THEME ENGINE BRIDGE (Syncs SCSS --saanskara-* Variables -> ImGui!)
// ============================================================================
static ImVec4 hex_to_imvec4(uint32_t rgb, float alpha = 1.0f) {
    float r = ((rgb >> 16) & 0xFF) / 255.0f;
    float g = ((rgb >> 8)  & 0xFF) / 255.0f;
    float b = (rgb         & 0xFF) / 255.0f;
    return ImVec4(r, g, b, alpha);
}

extern "C" {

EMSCRIPTEN_KEEPALIVE
void imgui_apply_raga_theme(uint32_t bg_canvas, uint32_t bg_surface, uint32_t bg_panel,
                            uint32_t accent_primary, uint32_t accent_alert, uint32_t text_main) {
    ImGuiStyle& style = ImGui::GetStyle();
    style.WindowRounding = 10.0f;
    style.FrameRounding  = 6.0f;
    style.WindowBorderSize = 0.0f;

    ImVec4 c_canvas  = hex_to_imvec4(bg_canvas);
    ImVec4 c_surface = hex_to_imvec4(bg_surface);
    ImVec4 c_panel   = hex_to_imvec4(bg_panel);
    ImVec4 c_accent  = hex_to_imvec4(accent_primary);
    ImVec4 c_alert   = hex_to_imvec4(accent_alert);
    ImVec4 c_text    = hex_to_imvec4(text_main);

    style.Colors[ImGuiCol_WindowBg]         = c_surface;
    style.Colors[ImGuiCol_ChildBg]          = c_canvas;
    style.Colors[ImGuiCol_FrameBg]          = c_panel;
    style.Colors[ImGuiCol_FrameBgHovered]   = hex_to_imvec4(accent_primary, 0.25f);
    style.Colors[ImGuiCol_FrameBgActive]    = c_accent;
    style.Colors[ImGuiCol_SliderGrab]       = c_accent;
    style.Colors[ImGuiCol_SliderGrabActive] = c_alert;
    style.Colors[ImGuiCol_Button]           = c_panel;
    style.Colors[ImGuiCol_ButtonHovered]    = c_accent;
    style.Colors[ImGuiCol_ButtonActive]     = c_alert;
    style.Colors[ImGuiCol_Text]             = c_text;
    style.Colors[ImGuiCol_Border]           = c_panel;

    ImPlotStyle& plot_style = ImPlot::GetStyle();
    plot_style.Colors[ImPlotCol_PlotBg]    = c_canvas;
    plot_style.Colors[ImPlotCol_FrameBg]   = c_surface;
    plot_style.Colors[ImPlotCol_Line]      = c_accent;
    plot_style.Colors[ImPlotCol_AxisGrid]  = hex_to_imvec4(accent_primary, 0.18f);
}

EMSCRIPTEN_KEEPALIVE
void imgui_set_canvas_size(int width, int height) {
    g_canvas_w = width > 100 ? width : 100;
    g_canvas_h = height > 100 ? height : 100;
}

EMSCRIPTEN_KEEPALIVE
void imgui_on_mouse_move(float x, float y) {
    ImGui::GetIO().AddMousePosEvent(x, y);
}

EMSCRIPTEN_KEEPALIVE
void imgui_on_mouse_button(int button, bool down) {
    ImGui::GetIO().AddMouseButtonEvent(button, down);
}

EMSCRIPTEN_KEEPALIVE
void imgui_on_mouse_wheel(float dx, float dy) {
    ImGui::GetIO().AddMouseWheelEvent(dx, dy);
}

} // extern "C"

// ============================================================================
// 4. 120FPS FRAME RENDERER (Dear ImGui + imgui-knobs + ImPlot)
// ============================================================================
static void render_frame() {
    compute_dsp_frame();

    ImGuiIO& io = ImGui::GetIO();
    io.DisplaySize = ImVec2((float)g_canvas_w, (float)g_canvas_h);

    ImGui_ImplOpenGL3_NewFrame();
    ImGui::NewFrame();

    // Fill the entire <canvas> seamlessly (no floating title bar!)
    ImGui::SetNextWindowPos(ImVec2(0, 0));
    ImGui::SetNextWindowSize(io.DisplaySize);
    ImGuiWindowFlags flags = ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
                             ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoCollapse |
                             ImGuiWindowFlags_NoBringToFrontOnFocus;

    ImGui::Begin("SaanskaraSitarSynthRack", nullptr, flags);

    // LEFT COLUMN: 4 Rotary Synth Knobs via imgui-knobs
    ImGui::BeginChild("KnobsPanel", ImVec2(320, 0), true);
    ImGui::Text("🪕 SAANSKARA RAGA DSP RACK");
    ImGui::Spacing();

    if (ImGuiKnobs::Knob("Sa (Hz)", &g_synth.root_hz, 110.0f, 440.0f, 1.0f, "%.0fHz", ImGuiKnobVariant_WiperDot, 56.0f)) {
        js_notify_knob_changed("root_hz", g_synth.root_hz);
    }
    ImGui::SameLine();
    if (ImGuiKnobs::Knob("Jawari", &g_synth.jawari_buzz, 0.0f, 1.0f, 0.01f, "%.2f", ImGuiKnobVariant_WiperDot, 56.0f)) {
        js_notify_knob_changed("jawari_buzz", g_synth.jawari_buzz);
    }
    ImGui::SameLine();
    if (ImGuiKnobs::Knob("Tarab Res", &g_synth.resonance, 0.0f, 1.0f, 0.01f, "%.2f", ImGuiKnobVariant_WiperDot, 56.0f)) {
        js_notify_knob_changed("resonance", g_synth.resonance);
    }
    ImGui::SameLine();
    if (ImGuiKnobs::Knob("Drive", &g_synth.analog_drive, 0.5f, 4.0f, 0.02f, "%.1fx", ImGuiKnobVariant_WiperDot, 56.0f)) {
        js_notify_knob_changed("analog_drive", g_synth.analog_drive);
    }

    ImGui::Spacing();
    ImGui::Separator();
    ImGui::TextDisabled("GPU FPS: %.1f • 512-pt C++ Scope", io.Framerate);
    ImGui::EndChild();

    ImGui::SameLine();

    // RIGHT COLUMN: Real-Time Dual-Trace Oscilloscope via ImPlot!
    ImGui::BeginChild("ScopePanel", ImVec2(0, 0), false);
    if (ImPlot::BeginPlot("##RagaOscilloscope", ImVec2(-1, -1), ImPlotFlags_NoMenus | ImPlotFlags_NoBoxSelect)) {
        ImPlot::SetupAxes("Time (ms)", "Amplitude", ImPlotAxisFlags_NoLabel, ImPlotAxisFlags_Lock);
        ImPlot::SetupAxesLimits(0.0, 10.0, -1.25, 1.25, ImGuiCond_Always);

        // 1. Shaded Jawari Overtone Layer
        ImPlot::PushStyleVar(ImPlotStyleVar_FillAlpha, 0.22f);
        ImPlot::PlotShaded("Jawari Harmonics", g_synth.time_axis, g_synth.jawari_layer, SaanskaraSynthState::SCOPE_POINTS);
        ImPlot::PopStyleVar();

        // 2. Primary Analog-Saturated Output Wave
        ImPlot::PushStyleVar(ImPlotStyleVar_LineWeight, 2.5f);
        ImPlot::PlotLine("Master Sitar Wave", g_synth.time_axis, g_synth.wave_out, SaanskaraSynthState::SCOPE_POINTS);
        ImPlot::PopStyleVar();

        ImPlot::EndPlot();
    }
    ImGui::EndChild();

    ImGui::End();

    // Render to WebGL2 Framebuffer
    ImGui::Render();
    glViewport(0, 0, g_canvas_w, g_canvas_h);
    glClearColor(0.04f, 0.05f, 0.09f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    ImGui_ImplOpenGL3_RenderDrawData(ImGui::GetDrawData());
}

// ============================================================================
// 5. INITIALIZATION ENTRYPOINT TARGETING `#imgui-synth-canvas`
// ============================================================================
extern "C" EMSCRIPTEN_KEEPALIVE
int init_saanskara_imgui(const char* canvas_selector) {
    EmscriptenWebGLContextAttributes attrs;
    emscripten_webgl_init_context_attributes(&attrs);
    attrs.majorVersion = 2; // WebGL2 (OpenGL ES 3.0)
    attrs.minorVersion = 0;

    g_gl_ctx = emscripten_webgl_create_context(canvas_selector, &attrs);
    if (g_gl_ctx <= 0) return -1;
    emscripten_webgl_make_context_current(g_gl_ctx);

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImPlot::CreateContext();

    // Apply default Midnight Studio Raga theme
    imgui_apply_raga_theme(0x090d16, 0x111827, 0x1e293b, 0xf59e0b, 0xe11d48, 0xf8fafc);

    ImGui_ImplOpenGL3_Init("#version 300 es");
    emscripten_set_main_loop(render_frame, 0, false);
    return 0;
}