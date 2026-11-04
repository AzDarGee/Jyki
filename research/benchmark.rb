#!/usr/bin/env ruby
# frozen_string_literal: true

# =============================================================================
# SAANSKARA 128-SAMPLE QUANTUM BENCHMARK (Ruby + C)
# Proves how fast C processes a single 128-sample Web Audio Render Quantum
# compared to the browser's hard real-time deadline at 44.1kHz - 192kHz.
# =============================================================================

require 'fiddle'
require 'fiddle/import'

SO_FILE = '/tmp/libquantum_test.so'

# Compile a 16-Band Parametric Biquad EQ operating on a 128-sample quantum
c_code = <<~C
  #include <stdint.h>

  typedef struct { float b0, b1, b2, a1, a2, z1, z2; } Biquad;
  static Biquad bands[16];

  // Processes 1 Web Audio Render Quantum (128 samples) through all 16 EQ bands
  void process_128_quantum(float* restrict buf) {
    for (int i = 0; i < 128; i++) {
      float x = buf[i];
      for (int b = 0; b < 16; b++) {
        float y = bands[b].b0 * x + bands[b].z1;
        bands[b].z1 = bands[b].b1 * x - bands[b].a1 * y + bands[b].z2;
        bands[b].z2 = bands[b].b2 * x - bands[b].a2 * y;
        x = y;
      }
      buf[i] = x;
    }
  }
C

IO.popen("gcc -O3 -ffast-math -shared -fPIC -xc - -o #{SO_FILE}", 'w') { |io| io.write(c_code) }

module QuantumBench
  extend Fiddle::Importer
  dlload SO_FILE
  extern 'void process_128_quantum(float*)'
end

# Allocate 1 Web Audio Render Quantum = 128 float32 samples (512 bytes of RAM)
quantum_128_buf = Array.new(128) { rand(-1.0..1.0) }.pack('f*')

# Measure average C execution time over 10,000 blocks of 128 samples
iterations = 10_000
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
iterations.times { QuantumBench.process_128_quantum(quantum_128_buf) }
avg_ns = (Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond) - t0) / iterations
avg_us = (avg_ns / 1000.0).round(3)

puts "⚡ C DSP Time for 128-Sample Quantum (16-Band EQ): #{avg_us} µs (#{avg_ns} nanoseconds!)\n\n"

[44_100, 48_000, 96_000, 176_400, 192_000, 384_000].each do |rate|
  deadline_us = (128.0 / rate) * 1_000_000.0
  cpu_load_pct = ((avg_us / deadline_us) * 100.0).round(2)
  puts format(
    "🎵 %6d Hz | Deadline per 128 samples: %7.1f µs | C DSP Load: %5.2f%% CPU",
    rate, deadline_us, cpu_load_pct
  )
end