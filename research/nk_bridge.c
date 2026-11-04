// nk_bridge.c
// Compile on Linux:
//   gcc -O3 -shared -fPIC nk_bridge.c -o libnkbridge.so -lglfw -lGL -lm
// Compile on macOS:
//   clang -O3 -dynamiclib nk_bridge.c -o libnkbridge.dylib -lglfw -framework
//   OpenGL

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <GLFW/glfw3.h>

#define NK_INCLUDE_FIXED_TYPES
#define NK_INCLUDE_STANDARD_IO
#define NK_INCLUDE_STANDARD_VARARGS
#define NK_INCLUDE_DEFAULT_ALLOCATOR
#define NK_INCLUDE_VERTEX_BUFFER_OUTPUT
#define NK_INCLUDE_FONT_BAKING
#define NK_INCLUDE_DEFAULT_FONT
#define NK_IMPLEMENTATION
#define NK_GLFW_GL2_IMPLEMENTATION

#include "nuklear.h"
#include "nuklear_glfw_gl2.h"

static GLFWwindow *win = NULL;
static struct nk_context *ctx = NULL;
static struct nk_colorf bg_color = {0.10f, 0.11f, 0.13f, 1.0f};

// --- 1. Lifecycle & Zero-CPU Event Loop ---

int nk_rb_init(const char *title, int width, int height) {
  if (!glfwInit())
    return 0;
  win = glfwCreateWindow(width, height, title, NULL, NULL);
  if (!win) {
    glfwTerminate();
    return 0;
  }
  glfwMakeContextCurrent(win);
  glfwSwapInterval(1); // Enable VSync

  ctx = nk_glfw3_init(win, NK_GLFW3_INSTALL_CALLBACKS);
  struct nk_font_atlas *atlas;
  nk_glfw3_font_stash_begin(&atlas);
  nk_glfw3_font_stash_end(); // Uses crisp built-in ProggyClean font (or load
                             // TTF here)
  return 1;
}

int nk_rb_should_close(void) { return glfwWindowShouldClose(win); }

// WaitEvents puts the thread to sleep until mouse/keyboard input arrives -> 0%
// idle CPU!
void nk_rb_begin_frame(int wait_for_input) {
  if (wait_for_input)
    glfwWaitEventsTimeout(0.1);
  else
    glfwPollEvents();
  nk_glfw3_new_frame();
}

void nk_rb_end_frame(void) {
  int width, height;
  glfwGetWindowSize(win, &width, &height);
  glViewport(0, 0, width, height);
  glClearColor(bg_color.r, bg_color.g, bg_color.b, bg_color.a);
  glClear(GL_COLOR_BUFFER_BIT);
  nk_glfw3_render(NK_ANTI_ALIASING_ON);
  glfwSwapBuffers(win);
}

void nk_rb_shutdown(void) {
  nk_glfw3_shutdown();
  glfwTerminate();
}

// --- 2. Windows, Layouts & Containers ---

int nk_rb_window_begin(const char *title, float x, float y, float w, float h,
                       int flags) {
  return nk_begin(ctx, title, nk_rect(x, y, w, h), (nk_flags)flags);
}

void nk_rb_window_end(void) { nk_end(ctx); }

void nk_rb_layout_row_dynamic(float height, int cols) {
  nk_layout_row_dynamic(ctx, height, cols);
}

void nk_rb_layout_row_static(float height, int item_width, int cols) {
  nk_layout_row_static(ctx, height, item_width, cols);
}

int nk_rb_group_begin(const char *title, int flags) {
  return nk_group_begin(ctx, title, (nk_flags)flags);
}

void nk_rb_group_end(void) { nk_group_end(ctx); }

int nk_rb_tree_push(int type, const char *title, int initial_state, int seed) {
  return nk_tree_push_id(ctx, (enum nk_tree_type)type, title,
                         (enum nk_collapse_states)initial_state, seed);
}

void nk_rb_tree_pop(void) { nk_tree_pop(ctx); }

// --- 3. Feature-Rich UI Components ---

void nk_rb_label(const char *text, int align) {
  nk_label(ctx, text, (nk_flags)align);
}

int nk_rb_button(const char *title) { return nk_button_label(ctx, title); }

int nk_rb_checkbox(const char *label, int *active) {
  return nk_checkbox_label(ctx, label, active);
}

int nk_rb_option(const char *label, int is_active) {
  return nk_option_label(ctx, label, is_active);
}

int nk_rb_slider_float(float min, float *val, float max, float step) {
  return nk_slider_float(ctx, min, val, max, step);
}

void nk_rb_property_int(const char *name, int min, int *val, int max, int step,
                        float inc_per_pixel) {
  nk_property_int(ctx, name, min, val, max, step, inc_per_pixel);
}

int nk_rb_edit_string(char *buffer, int max_len) {
  return (int)nk_edit_string_zero_terminated(ctx, NK_EDIT_FIELD, buffer,
                                             max_len, nk_filter_default);
}

int nk_rb_combo(const char **items, int count, int selected, int item_height,
                float w, float h) {
  return nk_combo(ctx, items, count, selected, item_height, nk_vec2(w, h));
}

int nk_rb_progress(uint64_t *cur, uint64_t max, int modifyable) {
  nk_size c = (nk_size)(*cur);
  int res = nk_progress(ctx, &c, (nk_size)max, modifyable);
  *cur = (uint64_t)c;
  return res;
}

void nk_rb_color_picker(float *r, float *g, float *b, float *a) {
  struct nk_colorf col = {*r, *g, *b, *a};
  if (nk_combo_begin_color(ctx, nk_rgb_cf(col), nk_vec2(200, 250))) {
    nk_layout_row_dynamic(ctx, 180, 1);
    col = nk_color_picker(ctx, col, NK_RGBA);
    nk_combo_end(ctx);
    *r = col.r;
    *g = col.g;
    *b = col.b;
    *a = col.a;
    bg_color = col; // Also update canvas background for visual feedback
  }
}