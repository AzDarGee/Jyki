# frozen_string_literal: true

require 'fiddle'
require 'fiddle/import'
require 'rbconfig'

# ============================================================================
# 1. ZERO-GEM C BINDINGS VIA FIDDLE
# ============================================================================
module Nuklear
  extend Fiddle::Importer

  ext = RbConfig::CONFIG['host_os'] =~ /darwin/ ? 'dylib' : 'so'
  dlload File.expand_path("libnkbridge.#{ext}", __dir__)

  # Nuklear Window & Widget Flags (Bitmasks from nuklear.h)
  WINDOW_BORDER       = (1 << 0)
  WINDOW_MOVABLE      = (1 << 1)
  WINDOW_SCALABLE     = (1 << 2)
  WINDOW_CLOSABLE     = (1 << 3)
  WINDOW_MINIMIZABLE  = (1 << 4)
  WINDOW_TITLE        = (1 << 6)
  WINDOW_DEFAULT      = WINDOW_BORDER | WINDOW_MOVABLE | WINDOW_SCALABLE | WINDOW_MINIMIZABLE | WINDOW_TITLE

  TEXT_LEFT           = 0x01 | 0x10 # NK_TEXT_ALIGN_LEFT | NK_TEXT_ALIGN_MIDDLE
  TEXT_CENTERED       = 0x02 | 0x10
  TREE_TAB            = 0
  TREE_NODE           = 1
  MINIMIZED           = 0
  MAXIMIZED           = 1

  # Lifecycle
  extern 'int nk_rb_init(const char*, int, int)'
  extern 'int nk_rb_should_close(void)'
  extern 'void nk_rb_begin_frame(int)'
  extern 'void nk_rb_end_frame(void)'
  extern 'void nk_rb_shutdown(void)'

  # Layout & Containers
  extern 'int nk_rb_window_begin(const char*, float, float, float, float, int)'
  extern 'void nk_rb_window_end(void)'
  extern 'void nk_rb_layout_row_dynamic(float, int)'
  extern 'void nk_rb_layout_row_static(float, int, int)'
  extern 'int nk_rb_group_begin(const char*, int)'
  extern 'void nk_rb_group_end(void)'
  extern 'int nk_rb_tree_push(int, const char*, int, int)'
  extern 'void nk_rb_tree_pop(void)'

  # UI Components
  extern 'void nk_rb_label(const char*, int)'
  extern 'int nk_rb_button(const char*)'
  extern 'int nk_rb_checkbox(const char*, int*)'
  extern 'int nk_rb_option(const char*, int)'
  extern 'int nk_rb_slider_float(float, float*, float, float)'
  extern 'void nk_rb_property_int(const char*, int, int*, int, int, float)'
  extern 'int nk_rb_edit_string(char*, int)'
  extern 'int nk_rb_combo(void*, int, int, int, float, float)'
  extern 'int nk_rb_progress(uint64_t*, uint64_t, int)'
  extern 'void nk_rb_color_picker(float*, float*, float*, float*)'

  # ==========================================================================
  # 2. ZERO-GC SHARED C-MEMORY HELPERS
  # Allocates tiny C buffers ONCE so the 60fps loop generates zero Ruby garbage
  # ==========================================================================
  class CVal
    attr_reader :ptr

    def initialize(type, initial)
      @type = type
      size = (type == :uint64 ? 8 : 4)
      @ptr = Fiddle::Pointer.malloc(size, Fiddle::RUBY_FREE)
      self.value = initial
    end

    def value
      case @type
      when :int    then @ptr[0, 4].unpack1('i!')
      when :float  then @ptr[0, 4].unpack1('f')
      when :uint64 then @ptr[0, 8].unpack1('Q')
      end
    end

    def value=(v)
      case @type
      when :int    then @ptr[0, 4] = [ v.to_i ].pack('i!')
      when :float  then @ptr[0, 4] = [ v.to_f ].pack('f')
      when :uint64 then @ptr[0, 8] = [ v.to_i ].pack('Q')
      end
    end
  end

  class CStringBuf
    attr_reader :ptr, :max_len

    def initialize(initial_text, max_len = 256)
      @max_len = max_len
      @ptr = Fiddle::Pointer.malloc(max_len, Fiddle::RUBY_FREE)
      @ptr[0, initial_text.bytesize + 1] = "#{initial_text}\0"
    end

    def to_s
      @ptr.to_s # Reads up to null-terminator
    end
  end

  class CStringArray
    attr_reader :ptr, :count

    def initialize(strings)
      @count = strings.size
      # Hold onto pointers so Ruby GC never collects them
      @c_strings = strings.map { |s| Fiddle::Pointer["#{s}\0"] }
      @ptr = Fiddle::Pointer[@c_strings.map(&:to_i).pack('Q*')]
    end
  end
end

# ============================================================================
# 3. SAANSKARA STUDIO DESKTOP APPLICATION
# ============================================================================
abort 'Failed to initialize Nuklear' if Nuklear.nk_rb_init('Saanskara Studio - Nuklear Engine', 900, 620).zero?

# --- Pre-allocated Application State (Lives in shared C/Ruby RAM) ---
project_name   = Nuklear::CStringBuf.new('Nataraja Generative Canvas', 128)
spanda_freq    = Nuklear::CVal.new(:float, 432.0)
iterations     = Nuklear::CVal.new(:int, 108)
high_dpi_mode  = Nuklear::CVal.new(:int, 1)
render_prog    = Nuklear::CVal.new(:uint64, 35)
selected_rasa  = 0
render_mode    = :sattvic

rasas = Nuklear::CStringArray.new([
  'Adbhuta (Wonder)',
  'Shringara (Beauty)',
  'Hasya (Mirth)',
  'Vira (Heroic)',
  'Shanta (Serenity)'
])

bg_r = Nuklear::CVal.new(:float, 0.10)
bg_g = Nuklear::CVal.new(:float, 0.11)
bg_b = Nuklear::CVal.new(:float, 0.13)
bg_a = Nuklear::CVal.new(:float, 1.00)

log_messages = [
  '[System] Nuklear C-Bridge initialized.',
  '[Memory] Footprint locked at ~14MB RAM.',
  '[Ottawa Weather] Still cold outside; GPU warm inside.'
]

# --- The Immediate Mode Loop ---
begin
  while Nuklear.nk_rb_should_close.zero?
    # Pass 1 to sleep until input (0% CPU when idle!)
    Nuklear.nk_rb_begin_frame(1)

    # --- MAIN STUDIO WINDOW ---
    if Nuklear.nk_rb_window_begin('Saanskara Control Deck', 20.0, 20.0, 440.0, 560.0, Nuklear::WINDOW_DEFAULT) != 0

      # 1. Text Input & Dropdown Combo
      Nuklear.nk_rb_layout_row_dynamic(28.0, 2)
      Nuklear.nk_rb_label('Kala (Artifact):', Nuklear::TEXT_LEFT)
      Nuklear.nk_rb_edit_string(project_name.ptr, project_name.max_len)

      Nuklear.nk_rb_layout_row_dynamic(28.0, 2)
      Nuklear.nk_rb_label('Primary Rasa:', Nuklear::TEXT_LEFT)
      selected_rasa = Nuklear.nk_rb_combo(rasas.ptr, rasas.count, selected_rasa, 25, 200.0, 180.0)

      # 2. Collapsible Tree Section: Parameters
      if Nuklear.nk_rb_tree_push(Nuklear::TREE_TAB, 'Spanda Harmonics & Physics', Nuklear::MAXIMIZED, 101) != 0
        Nuklear.nk_rb_layout_row_dynamic(26.0, 2)
        Nuklear.nk_rb_label(format('Frequency (%.1f Hz):', spanda_freq.value), Nuklear::TEXT_LEFT)
        Nuklear.nk_rb_slider_float(20.0, spanda_freq.ptr, 8000.0, 1.0)

        Nuklear.nk_rb_layout_row_dynamic(26.0, 1)
        Nuklear.nk_rb_property_int('Samkhya Iterations:', 1, iterations.ptr, 10_000, 10, 1.0)

        # Radio Buttons (Gunas)
        Nuklear.nk_rb_layout_row_dynamic(26.0, 3)
        render_mode = :sattvic if Nuklear.nk_rb_option('Sattvic (Pure)', render_mode == :sattvic ? 1 : 0) != 0
        render_mode = :rajasic if Nuklear.nk_rb_option('Rajasic (Fast)', render_mode == :rajasic ? 1 : 0) != 0
        render_mode = :tamasic if Nuklear.nk_rb_option('Tamasic (Raw)',  render_mode == :tamasic ? 1 : 0) != 0

        Nuklear.nk_rb_tree_pop
      end

      # 3. Collapsible Tree Section: Aesthetics & Output
      if Nuklear.nk_rb_tree_push(Nuklear::TREE_TAB, 'Maya (Canvas & Aesthetics)', Nuklear::MAXIMIZED, 102) != 0
        Nuklear.nk_rb_layout_row_dynamic(28.0, 2)
        Nuklear.nk_rb_label('Backdrop Color:', Nuklear::TEXT_LEFT)
        Nuklear.nk_rb_color_picker(bg_r.ptr, bg_g.ptr, bg_b.ptr, bg_a.ptr)

        Nuklear.nk_rb_layout_row_dynamic(26.0, 1)
        Nuklear.nk_rb_checkbox('Enable Retina / High-DPI Antialiasing', high_dpi_mode.ptr)

        Nuklear.nk_rb_layout_row_dynamic(22.0, 1)
        Nuklear.nk_rb_label("Synthesis Progress: #{render_prog.value}%", Nuklear::TEXT_LEFT)
        Nuklear.nk_rb_progress(render_prog.ptr, 100, 1) # 1 = user can drag progress bar too!

        Nuklear.nk_rb_tree_pop
      end

      # 4. Action Buttons
      Nuklear.nk_rb_layout_row_dynamic(36.0, 2)
      if Nuklear.nk_rb_button('Ignite Spanda (Execute)') != 0
        render_prog.value = (render_prog.value + 15) % 105
        log_messages << format('[Run] %s | %.1fHz | %s mode', project_name.to_s, spanda_freq.value, render_mode)
      end

      if Nuklear.nk_rb_button('Purge Karma (Reset)') != 0
        spanda_freq.value = 432.0
        iterations.value  = 108
        render_prog.value = 0
        log_messages.clear
        log_messages << '[Reset] Tabula rasa achieved.'
      end
    end
    Nuklear.nk_rb_window_end

    # --- SECOND FLOATING SUB-WINDOW: CONSOLE & TELEMETRY ---
    if Nuklear.nk_rb_window_begin('Sutradhara Telemetry', 480.0, 20.0, 390.0, 340.0, Nuklear::WINDOW_DEFAULT) != 0
      Nuklear.nk_rb_layout_row_dynamic(240.0, 1)
      if Nuklear.nk_rb_group_begin('EventLog', Nuklear::WINDOW_BORDER | Nuklear::WINDOW_TITLE) != 0
        Nuklear.nk_rb_layout_row_dynamic(20.0, 1)
        log_messages.last(15).each do |msg|
          Nuklear.nk_rb_label(msg, Nuklear::TEXT_LEFT)
        end
        Nuklear.nk_rb_group_end
      end
    end
    Nuklear.nk_rb_window_end

    Nuklear.nk_rb_end_frame
  end
ensure
  Nuklear.nk_rb_shutdown
end
