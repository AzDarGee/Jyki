# frozen_string_literal: true

require 'fiddle'
require 'fiddle/import'
require 'etc'
require 'libui'

# ============================================================================
# 1. ZERO-COPY C MEMORY & FIDDLE BRIDGE
# ============================================================================
module NatarajaEngine
  extend Fiddle::Importer

  ext = RbConfig::CONFIG['host_os'] =~ /darwin/ ? 'dylib' : 'so'
  dlload File.expand_path("libnataraja.#{ext}", __dir__)

  # Exact mirror of the 32-byte C `JobState` struct!
  JobState = struct [
    'int completed_chunks',
    'int total_chunks',
    'int status',      # 0=Idle, 1=Running, 2=Done, 3=Cancelled
    'int num_cores',
    'void* buffer',
    'double checksum'
  ]

  extern 'void launch_parallel_job(JobState*)'
  extern 'void cancel_parallel_job(JobState*)'
end

# ============================================================================
# 2. ALLOCATE SHARED MEMORY (ONCE! ZERO GC OVERHEAD!)
# ============================================================================
TOTAL_CHUNKS = 4_000
CORES        = Etc.nprocessors

# Allocate shared data buffer for 4,000 doubles (32KB)
shared_data_buffer = Fiddle::Pointer.malloc(
  TOTAL_CHUNKS * Fiddle::SIZEOF_DOUBLE,
  Fiddle::RUBY_FREE
)

# Allocate our 32-byte shared control block
job = NatarajaEngine::JobState.malloc(Fiddle::RUBY_FREE)
job.completed_chunks = 0
job.total_chunks     = TOTAL_CHUNKS
job.status           = 0
job.num_cores        = CORES
job.buffer           = shared_data_buffer
job.checksum         = 0.0

# ============================================================================
# 3. NATIVE DESKTOP UI (LibUI)
# ============================================================================
UI = LibUI
UI.init

@callbacks = []
def pin(&block)
  @callbacks << block
  block
end

main_window = UI.new_window("Saanskara Nataraja Engine (#{CORES} CPU Cores)", 520, 260, 1)
UI.window_set_margined(main_window, 1)

vbox = UI.new_vertical_box
UI.box_set_padded(vbox, 1)
UI.window_set_child(main_window, vbox)

# Responsive test input: type here while all CPU cores are at 100% to prove zero UI lag!
test_entry = UI.new_entry
UI.entry_set_text(test_entry, 'Type here while cores are at 100% — zero lag!')
UI.box_append(vbox, test_entry, 0)

# Smooth Progress Bar
progress_bar = UI.new_progress_bar
UI.box_append(vbox, progress_bar, 0)

# Live Telemetry Label
telemetry_label = UI.new_label("Status: Shanta (Idle) | Cores Ready: #{CORES}")
UI.box_append(vbox, telemetry_label, 0)

# Horizontal Button Box
hbox = UI.new_horizontal_box
UI.box_set_padded(hbox, 1)
UI.box_append(vbox, hbox, 0)

start_btn  = UI.new_button("Unleash #{CORES} Cores (C Tandava)")
cancel_btn = UI.new_button('Abort Job')
UI.control_disable(cancel_btn)

UI.box_append(hbox, start_btn, 1)
UI.box_append(hbox, cancel_btn, 0)

@start_time = 0.0

# ============================================================================
# 4. THE 60FPS LOCK-FREE SHARED MEMORY POLLING LOOP
# ============================================================================
poll_progress = pin do |_data|
  status = job.status
  done   = job.completed_chunks
  pct    = ((done.to_f / TOTAL_CHUNKS) * 100).round

  UI.progress_bar_set_value(progress_bar, pct)

  if status == 1 # Running
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @start_time
    UI.label_set_text(
      telemetry_label,
      format("Running on %d cores: %d / %d chunks (%d%%) — %.2fs", CORES, done, TOTAL_CHUNKS, pct, elapsed)
    )
    1 # Return 1 in LibUI to keep the 16ms (60fps) timer repeating!
  else
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @start_time
    if status == 2 # Completed!
      UI.label_set_text(
        telemetry_label,
        format("Done in %.2fs! Checksum: %.2f (Zero-Copy Shared RAM)", elapsed, job.checksum)
      )
    elsif status == 3 # Aborted!
      UI.label_set_text(telemetry_label, "Aborted at #{pct}% (#{done} chunks) after #{elapsed.round(2)}s.")
    end

    UI.control_enable(start_btn)
    UI.control_disable(cancel_btn)
    0 # Return 0 in LibUI to stop the timer until next run!
  end
end

# --- Button Click Handlers ---
UI.button_on_clicked(start_btn, pin do |_btn, _data|
  UI.control_disable(start_btn)
  UI.control_enable(cancel_btn)
  @start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # 1. Fire off detached C threads across all cores (returns in 0.05ms!)
  NatarajaEngine.launch_parallel_job(job)

  # 2. Start 60fps UI timer (every 16ms) to read the shared C struct
  UI.timer(16, poll_progress, nil)
end)

UI.button_on_clicked(cancel_btn, pin do |_btn, _data|
  # Flips a single atomic integer in C memory—all cores halt within microseconds!
  NatarajaEngine.cancel_parallel_job(job)
end)

UI.window_on_closing(main_window, pin do |_win, _data|
  NatarajaEngine.cancel_parallel_job(job)
  UI.quit
  1
end)

# ============================================================================
# 5. CTRL+C / SIGTERM SUPPORT
# ============================================================================
# UI.main blocks inside native code, so Ruby never gets a chance to run signal
# handlers and Ctrl+C looks like a hang. A cheap keep-alive timer hands control
# back to Ruby every 200ms so a trapped signal can shut the UI down cleanly.
@shutdown_requested = false
%w[INT TERM].each { |sig| trap(sig) { @shutdown_requested = true } }

keep_alive = pin do |_data|
  if @shutdown_requested
    NatarajaEngine.cancel_parallel_job(job)
    UI.quit
    0 # Stop the timer
  else
    1 # Keep ticking
  end
end
UI.timer(200, keep_alive, nil)

# ============================================================================
# 6. MACOS: BECOME A REAL FOREGROUND APP
# ============================================================================
# A bare `ruby` process launched from a terminal has no activation policy, so
# the window is created but never shown (no Dock icon, never frontmost).
# Promote the process to a regular app and activate it via the Obj-C runtime.
def bring_app_to_front
  return unless RbConfig::CONFIG['host_os'] =~ /darwin/

  objc = Fiddle.dlopen('/usr/lib/libobjc.A.dylib')
  ptr  = Fiddle::TYPE_VOIDP
  get_class = Fiddle::Function.new(objc['objc_getClass'], [ptr], ptr)
  sel       = Fiddle::Function.new(objc['sel_registerName'], [ptr], ptr)
  msg       = objc['objc_msgSend']
  send_obj  = Fiddle::Function.new(msg, [ptr, ptr], ptr)
  send_long = Fiddle::Function.new(msg, [ptr, ptr, Fiddle::TYPE_LONG], Fiddle::TYPE_CHAR)
  send_bool = Fiddle::Function.new(msg, [ptr, ptr, Fiddle::TYPE_INT], Fiddle::TYPE_VOID)

  app = send_obj.call(get_class.call('NSApplication'), sel.call('sharedApplication'))
  send_long.call(app, sel.call('setActivationPolicy:'), 0) # 0 = Regular
  send_bool.call(app, sel.call('activateIgnoringOtherApps:'), 1)
rescue StandardError => e
  warn "Could not activate app window: #{e.message}"
end

UI.control_show(main_window)
bring_app_to_front
UI.main
UI.quit
