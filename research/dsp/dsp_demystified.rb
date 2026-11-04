#!/usr/bin/env ruby
# frozen_string_literal: true

# =============================================================================
# THE 5 SECRETS OF DSP: Synth, Fader, Tube Drive, DJ Filter & Echo in Pure C
# Run on your Mac: `ruby dsp_demystified.rb`
# =============================================================================

require 'fiddle'
require 'fiddle/import'
require 'rbconfig'

ext = RbConfig::CONFIG['host_os'].match?(/darwin/i) ? 'dylib' : 'so'
flag = ext == 'dylib' ? '-dynamiclib' : '-shared -fPIC'
lib_file = "/tmp/libdsp_secrets.#{ext}"

c_code = <<~C
  #include <math.h>
  #include <stdint.h>

  // A complete mini-DAW DSP chain in 25 lines of C!
  void run_daw_dsp_chain(
      float* samples,        // Array of sound numbers (-1.0 to +1.0)
      uint32_t count,        // How many samples (e.g., 48000 = 1 second)
      float fader_volume,    // 1. MIXER FADER: 0.0 (mute) to 1.0 (full)
      float tube_drive,      // 2. SATURATION:  1.0 (clean) to 5.0 (crunchy)
      float dj_lowpass_amt   // 3. DJ FILTER:   0.05 (muffled sub-bass) to 1.0 (wide open)
  ) {
      float prev_sample = 0.0f;

      for (uint32_t i = 0; i < count; i++) {
          float s = samples[i];

          // EFFECT 1: Warm Analog Tube Saturation (Soft-clipping wave shaper)
          s = tanhf(s * tube_drive);

          // EFFECT 2: DJ Deck Low-Pass Filter (Smooths fast treble, keeps slow bass)
          s = prev_sample + dj_lowpass_amt * (s - prev_sample);
          prev_sample = s;

          // EFFECT 3: Slapback Echo / Delay (Add sound from 100 samples ago)
          if (i >= 100) {
              s += samples[i - 100] * 0.35f;
          }

          // EFFECT 4: Channel Mixer Fader (Simple multiplication!)
          samples[i] = s * fader_volume;
      }
  }
C

system("clang -O3 -ffast-math #{flag} -xc - -o #{lib_file}", input: c_code, exception: true)

module MiniDsp
  extend Fiddle::Importer
  dlload "/tmp/libdsp_secrets.#{RbConfig::CONFIG['host_os'].match?(/darwin/i) ? 'dylib' : 'so'}"
  extern 'void run_daw_dsp_chain(float*, unsigned int, float, float, float)'
end

# Generate a raw 440Hz Concert 'A' note (48,000 floats between -1.0 and +1.0)
raw_wave = Array.new(48_000) { |i| Math.sin(2.0 * Math::PI * 440.0 * (i / 48_000.0)) }.pack('f*')

t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC, :microsecond)
MiniDsp.run_daw_dsp_chain(raw_wave, 48_000, 0.8, 2.5, 0.25)
dt = Process.clock_gettime(Process::CLOCK_MONOTONIC, :microsecond) - t0

processed = raw_wave.unpack('f10')
puts "⚡ Processed 1 full second of 4-Effect Studio DSP in #{dt} microseconds!"
puts "🎵 First 5 audio sample floats sent to speaker: #{processed.first(5).map { |f| f.round(4) }}"
