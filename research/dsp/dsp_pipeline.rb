#!/usr/bin/env ruby
# frozen_string_literal: true

# =============================================================================
# SAANSKARA STUDIOS — SELF-COMPILING RUBY + C11 DSP ENGINE & PIPELINE
# Run directly: ruby dsp_pipeline.rb
# Zero gems. Zero external files required. Compiles C11 inline in ~150ms.
# =============================================================================

require 'fiddle'
require 'fiddle/import'
require 'rbconfig'
require 'digest'

module SaanskaraDSP
  # ---------------------------------------------------------------------------
  # 1. AUTO-COMPILER: Extracts C code from __END__, compiles to shared lib
  # ---------------------------------------------------------------------------
  def self.ensure_compiled!
    c_source = DATA.read
    hash     = Digest::SHA256.hexdigest(c_source)[0, 12]
    ext      = RbConfig::CONFIG['DLEXT'] || 'so'
    os       = RbConfig::CONFIG['host_os']

    # Store compiled binary in /tmp (or local dir) keyed by source hash
    lib_path = File.expand_path(".libsaanskara_dsp_#{hash}.#{ext}", __dir__ || Dir.pwd)

    unless File.exist?(lib_path)
      # Clean up any older cached builds in this folder
      Dir.glob(File.expand_path(".libsaanskara_dsp_*.#{ext}", __dir__ || Dir.pwd)).each do |old|
        File.delete(old) rescue nil
      end

      c_file = File.expand_path(".dsp_engine_tmp.c", __dir__ || Dir.pwd)
      File.write(c_file, c_source)

      cc = ENV['CC'] || RbConfig::CONFIG['CC'] || 'cc'
      shared_flag = os =~ /darwin|mac os/i ? '-dynamiclib' : '-shared'

      cmd = "#{cc} -O3 -ffast-math -Wall -Wextra #{shared_flag} -fPIC #{c_file} -lm -o #{lib_path}"
      print "⚡ [Saanskara DSP] Compiling native C11 kernel (#{ File.basename(lib_path) })... "
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      unless system(cmd)
        File.delete(c_file) rescue nil
        abort "\n❌ C Compilation failed! Ensure '#{cc}' (gcc/clang) is installed."
      end

      File.delete(c_file) rescue nil
      dt = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000.0).round(1)
      size_kb = (File.size(lib_path) / 1024.0).round(1)
      puts "Done in #{dt}ms! (Binary size: #{size_kb} KB)"
    end

    lib_path
  end

  LIB_PATH = ensure_compiled!

  # ---------------------------------------------------------------------------
  # 2. FFI BINDINGS (Pure Standard Library Fiddle)
  # ---------------------------------------------------------------------------
  extend Fiddle::Importer
  dlload LIB_PATH

  extern 'void* dsp_create(float)'
  extern 'void  dsp_destroy(void*)'
  extern 'int   dsp_reset_state(void*)'
  extern 'int   dsp_add_node(void*, int, float, float)'
  extern 'int   dsp_set_param(void*, int, float, float)'
  extern 'int   dsp_set_active(void*, int, int)'
  extern 'int   dsp_process(void*, const void*, void*, size_t)'
  extern 'int   dsp_analyze(const void*, size_t, void*, void*, void*)'

  NODE_BYPASS   = 0
  NODE_GAIN     = 1
  NODE_LPF_1P   = 2
  NODE_HPF_1P   = 3
  NODE_SOFTCLIP = 4
  NODE_DELAY    = 5

  # ---------------------------------------------------------------------------
  # 3. RUBY PIPELINE ORCHESTRATOR & DSL
  # ---------------------------------------------------------------------------
  class Pipeline
    attr_reader :sample_rate, :nodes, :node_specs

    def initialize(sample_rate = 48_000.0, &block)
      @sample_rate = sample_rate.to_f
      @handle = SaanskaraDSP.dsp_create(@sample_rate)
      raise 'Failed to allocate C DSP Arena' if @handle.null?

      # Attach C destructor safely so Ruby GC frees the arena automatically
      @handle.free = SaanskaraDSP['dsp_destroy']

      @nodes      = {} # name => node_index
      @node_specs = {} # name => metadata hash
      @in_buf     = String.new(capacity: 4096 * 4)
      @out_buf    = String.new(capacity: 4096 * 4)

      instance_eval(&block) if block_given?
    end

    # --- DSL Node Builders ---

    def gain(name, db: 0.0)
      linear = db_to_linear(db)
      register_node(name, :gain, NODE_GAIN, linear, 0.0, db: db)
    end

    def lowpass(name, cutoff_hz: 1000.0)
      alpha = cutoff_to_alpha(cutoff_hz)
      register_node(name, :lowpass, NODE_LPF_1P, alpha, 0.0, cutoff_hz: cutoff_hz)
    end

    def highpass(name, cutoff_hz: 120.0)
      alpha = cutoff_to_alpha(cutoff_hz)
      register_node(name, :highpass, NODE_HPF_1P, alpha, 0.0, cutoff_hz: cutoff_hz)
    end

    def saturate(name, drive: 1.5, mix: 1.0)
      register_node(name, :saturate, NODE_SOFTCLIP, drive.to_f, mix.clamp(0.0, 1.0).to_f, drive: drive, mix: mix)
    end

    def comb_delay(name, delay_ms: 15.0, feedback: 0.4)
      delay_samples = ((delay_ms.to_f / 1000.0) * @sample_rate).round.clamp(1, 2047).to_f
      register_node(name, :comb_delay, NODE_DELAY, delay_samples, feedback.clamp(-0.98, 0.98).to_f,
                    delay_ms: delay_ms, feedback: feedback)
    end

    # --- Live Parameter Control ---

    def set_gain(name, db:)
      idx = fetch_idx(name)
      @node_specs[name][:db] = db
      SaanskaraDSP.dsp_set_param(@handle, idx, db_to_linear(db), 0.0)
    end

    def set_cutoff(name, cutoff_hz:)
      idx = fetch_idx(name)
      @node_specs[name][:cutoff_hz] = cutoff_hz
      SaanskaraDSP.dsp_set_param(@handle, idx, cutoff_to_alpha(cutoff_hz), 0.0)
    end

    def set_saturate(name, drive:, mix: 1.0)
      idx = fetch_idx(name)
      @node_specs[name][:drive] = drive
      @node_specs[name][:mix]   = mix
      SaanskaraDSP.dsp_set_param(@handle, idx, drive.to_f, mix.clamp(0.0, 1.0).to_f)
    end

    def bypass(name, bypassed = true)
      idx = fetch_idx(name)
      @node_specs[name][:active] = !bypassed
      SaanskaraDSP.dsp_set_active(@handle, idx, bypassed ? 0 : 1)
    end

    def reset!
      SaanskaraDSP.dsp_reset_state(@handle)
    end

    # --- Real-Time Processing & C-Level Telemetry ---

    def process(input_floats)
      frames = input_floats.size
      raise ArgumentError, "Max block size is 4096 frames (got #{frames})" if frames > 4096

      # Pack Ruby Array -> contiguous 32-bit float C buffer
      @in_buf  = input_floats.pack('f*')
      @out_buf = "\0".b * (frames * 4)

      status = SaanskaraDSP.dsp_process(@handle, @in_buf, @out_buf, frames)
      raise "DSP Engine Error (code #{status})" unless status == 0

      @out_buf.unpack('f*')
    end

    def self.analyze(samples)
      buf  = samples.pack('f*')
      peak = [ 0.0 ].pack('f')
      rms  = [ 0.0 ].pack('f')
      dc   = [ 0.0 ].pack('f')

      SaanskaraDSP.dsp_analyze(buf, samples.size, peak, rms, dc)
      pk_val  = peak.unpack1('f')
      rms_val = rms.unpack1('f')

      {
        peak:    pk_val.round(4),
        peak_db: (pk_val > 1e-9 ? 20.0 * Math.log10(pk_val) : -120.0).round(2),
        rms:     rms_val.round(4),
        rms_db:  (rms_val > 1e-9 ? 20.0 * Math.log10(rms_val) : -120.0).round(2),
        dc_offset: dc.unpack1('f').round(5)
      }
    end

    private

    def register_node(name, kind, type_id, p1, p2, meta = {})
      idx = SaanskaraDSP.dsp_add_node(@handle, type_id, p1.to_f, p2.to_f)
      raise "Pipeline full (max 64 nodes)" if idx < 0

      @nodes[name] = idx
      @node_specs[name] = { index: idx, kind: kind, active: true }.merge(meta)
      idx
    end

    def fetch_idx(name)
      @nodes.fetch(name) { raise KeyError, "Unknown DSP node #{name.inspect}" }
    end

    def db_to_linear(db)
      10.0**(db.to_f / 20.0)
    end

    def cutoff_to_alpha(cutoff_hz)
      fc = cutoff_hz.to_f.clamp(1.0, @sample_rate * 0.49)
      1.0 - Math.exp(-2.0 * Math::PI * fc / @sample_rate)
    end
  end
end

# =============================================================================
# 4. VISUALIZATION & BENCHMARK HARNESS (Runs when executed as a script)
# =============================================================================
if __FILE__ == $PROGRAM_NAME
  def draw_ascii_wave(title, samples, width: 64, height: 9)
    puts "\n┌─ #{title} " + ("─" * [ 0, width - title.length - 4 ].max) + "┐"
    step = [ 1, samples.size / width ].max
    cols = (0...width).map { |c| samples[[ c * step, samples.size - 1 ].min] }
    mid  = height / 2

    (0...height).each do |row|
      line = String.new("│")
      cols.each do |val|
        # Map [-1.0..1.0] to [height-1..0]
        mapped = ((1.0 - val.clamp(-1.0, 1.0)) * 0.5 * (height - 1)).round
        if mapped == row
          line << "█"
        elsif row == mid
          line << "─"
        elsif (mapped < mid && row > mapped && row < mid) || (mapped > mid && row < mapped && row > mid)
          line << "▒"
        else
          line << " "
        end
      end
      line << "│"
      puts line
    end
    puts "└" + ("─" * width) + "┘"
  end

  puts "=================================================================="
  puts " 🪔 SAANSKARA STUDIOS — RUBY + C11 NATIVE DSP PIPELINE DEMO"
  puts "=================================================================="

  sample_rate = 96_000.0
  frames      = 512

  # 1. Build the DSP Pipeline using our Ruby DSL
  engine = SaanskaraDSP::Pipeline.new(sample_rate) do
    highpass   :dc_blocker,  cutoff_hz: 40.0
    gain       :pre_boost,   db: 4.5
    lowpass    :silk_filter, cutoff_hz: 1800.0
    saturate   :tape_warmth, drive: 2.2, mix: 0.85
    comb_delay :room_slap,   delay_ms: 2.5, feedback: 0.35
  end

  puts "\n[Active DSP Pipeline Graph]"
  engine.node_specs.each do |name, spec|
    puts "  Node ##{spec[:index]} :#{name.to_s.ljust(12)} -> #{spec[:kind].to_s.upcase.ljust(11)} #{spec.except(:index, :kind, :active)}"
  end

  # 2. Synthesize a rich test signal: Fundamental (220Hz) + harsh 5th harmonic (1100Hz) + high fizz (6000Hz) + DC offset
  raw_signal = Array.new(frames) do |n|
    t = n / sample_rate
    0.15 + # Intentional DC offset for the highpass filter to clean up
      0.55 * Math.sin(2.0 * Math::PI * 220.0 * t) +
      0.30 * Math.sin(2.0 * Math::PI * 1100.0 * t) +
      0.25 * Math.sin(2.0 * Math::PI * 6000.0 * t)
  end

  # 3. Process through C Engine
  processed_signal = engine.process(raw_signal)

  # 4. Compare Telemetry
  in_stats  = SaanskaraDSP::Pipeline.analyze(raw_signal)
  out_stats = SaanskaraDSP::Pipeline.analyze(processed_signal)

  puts "\n[Signal Telemetry]"
  puts "  INPUT  -> Peak: #{in_stats[:peak]} (#{in_stats[:peak_db]} dB) | RMS: #{in_stats[:rms]} (#{in_stats[:rms_db]} dB) | DC Offset: #{in_stats[:dc_offset]}"
  puts "  OUTPUT -> Peak: #{out_stats[:peak]} (#{out_stats[:peak_db]} dB) | RMS: #{out_stats[:rms]} (#{out_stats[:rms_db]} dB) | DC Offset: #{out_stats[:dc_offset]}"

  # 5. Render ASCII Oscilloscopes
  draw_ascii_wave("RAW INPUT (220Hz + 1.1kHz + 6kHz Fizz + DC Offset)", raw_signal.first(256))
  draw_ascii_wave("SCULPTED OUTPUT (Filtered, Tape-Saturated & Comb-Delayed)", processed_signal.first(256))

  # 6. Live Parameter Automation Test
  engine.set_cutoff(:silk_filter, cutoff_hz: 450.0)
  engine.bypass(:room_slap, true)
  dark_signal = engine.process(raw_signal)
  dark_stats  = SaanskaraDSP::Pipeline.analyze(dark_signal)
  puts "\n[Live Tweak: Silk Filter dropped to 450Hz, Delay Bypassed]"
  puts "  DARK OUTPUT -> Peak: #{dark_stats[:peak]} (#{dark_stats[:peak_db]} dB) | RMS: #{dark_stats[:rms]} (#{dark_stats[:rms_db]} dB)"

  # 7. Real-Time Throughput Benchmark (1,000 blocks of 512 samples = 10.66 seconds of 48kHz audio)
  blocks = 1000
  t_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  blocks.times { engine.process(raw_signal) }
  elapsed_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t_start) * 1000.0
  audio_seconds = (blocks * frames) / sample_rate
  realtime_factor = (audio_seconds * 1000.0) / elapsed_ms

  puts "\n[Performance Benchmark (5-Node Chain + Ruby FFI Pack/Unpack)]"
  puts "  Processed #{blocks * frames} samples (#{audio_seconds.round(2)}s of 48kHz audio) in #{elapsed_ms.round(2)} ms"
  puts "  Speed: #{realtime_factor.round(1)}x faster than real-time (#{(elapsed_ms / blocks * 1000).round(1)} µs per 512-sample block)"
  puts "=================================================================="
end

__END__
// ============================================================================
// INLINE C11 DSP ENGINE KERNEL (Zero-Malloc Hot Loop, Arena Architecture)
// ============================================================================
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#define MAX_NODES 64
#define MAX_BLOCK_SIZE 4096
#define DELAY_BUF_SIZE 2048
#define DELAY_MASK (DELAY_BUF_SIZE - 1)

typedef enum {
    NODE_BYPASS   = 0,
    NODE_GAIN     = 1,
    NODE_LPF_1P   = 2,
    NODE_HPF_1P   = 3,
    NODE_SOFTCLIP = 4,
    NODE_DELAY    = 5
} NodeType;

typedef struct {
    int32_t  type;
    int32_t  active;
    float    param1;
    float    param2;
    float    z1;
    float    z2;
    uint32_t write_pos;
    float    delay_buf[DELAY_BUF_SIZE];
} DspNode;

typedef struct {
    uint32_t num_nodes;
    float    sample_rate;
    DspNode  nodes[MAX_NODES];
} DspPipeline;

DspPipeline* dsp_create(float sample_rate) {
    DspPipeline* p = (DspPipeline*)calloc(1, sizeof(DspPipeline));
    if (p) p->sample_rate = sample_rate;
    return p;
}

void dsp_destroy(DspPipeline* p) {
    if (p) free(p);
}

int32_t dsp_reset_state(DspPipeline* p) {
    if (!p) return -1;
    for (uint32_t i = 0; i < p->num_nodes; ++i) {
        p->nodes[i].z1 = 0.0f;
        p->nodes[i].z2 = 0.0f;
        p->nodes[i].write_pos = 0;
        memset(p->nodes[i].delay_buf, 0, sizeof(p->nodes[i].delay_buf));
    }
    return 0;
}

int32_t dsp_add_node(DspPipeline* p, int32_t type, float param1, float param2) {
    if (!p || p->num_nodes >= MAX_NODES) return -1;
    uint32_t idx = p->num_nodes++;
    memset(&p->nodes[idx], 0, sizeof(DspNode));
    p->nodes[idx].type   = type;
    p->nodes[idx].active = 1;
    p->nodes[idx].param1 = param1;
    p->nodes[idx].param2 = param2;
    return (int32_t)idx;
}

int32_t dsp_set_param(DspPipeline* p, int32_t node_idx, float param1, float param2) {
    if (!p || node_idx < 0 || (uint32_t)node_idx >= p->num_nodes) return -1;
    p->nodes[node_idx].param1 = param1;
    p->nodes[node_idx].param2 = param2;
    return 0;
}

int32_t dsp_set_active(DspPipeline* p, int32_t node_idx, int32_t active) {
    if (!p || node_idx < 0 || (uint32_t)node_idx >= p->num_nodes) return -1;
    p->nodes[node_idx].active = active;
    return 0;
}

int32_t dsp_process(DspPipeline* p, const float* restrict in, float* restrict out, size_t frames) {
    if (!p || !in || !out || frames == 0 || frames > MAX_BLOCK_SIZE) return -1;

    memcpy(out, in, frames * sizeof(float));

    for (uint32_t n = 0; n < p->num_nodes; ++n) {
        DspNode* node = &p->nodes[n];
        if (!node->active) continue;

        switch (node->type) {
            case NODE_GAIN: {
                const float g = node->param1;
                for (size_t i = 0; i < frames; ++i) {
                    out[i] *= g;
                }
                break;
            }
            case NODE_LPF_1P: {
                const float alpha = node->param1;
                float z1 = node->z1;
                for (size_t i = 0; i < frames; ++i) {
                    z1 += alpha * (out[i] - z1);
                    out[i] = z1;
                }
                node->z1 = z1;
                break;
            }
            case NODE_HPF_1P: {
                // Highpass = Input - Lowpass(Input)
                const float alpha = node->param1;
                float z1 = node->z1;
                for (size_t i = 0; i < frames; ++i) {
                    float x = out[i];
                    z1 += alpha * (x - z1);
                    out[i] = x - z1;
                }
                node->z1 = z1;
                break;
            }
            case NODE_SOFTCLIP: {
                const float drive = node->param1;
                const float mix   = node->param2;
                const float dry   = 1.0f - mix;
                for (size_t i = 0; i < frames; ++i) {
                    float clean = out[i];
                    float x = clean * drive;
                    float sat;
                    if (x > 3.0f) sat = 1.0f;
                    else if (x < -3.0f) sat = -1.0f;
                    else {
                        float x2 = x * x;
                        sat = x * (27.0f + x2) / (27.0f + 9.0f * x2);
                    }
                    out[i] = (clean * dry) + (sat * mix);
                }
                break;
            }
            case NODE_DELAY: {
                // Power-of-two ring buffer comb delay (zero modulo branch overhead!)
                const uint32_t delay_samples = ((uint32_t)node->param1) & DELAY_MASK;
                const float feedback = node->param2;
                uint32_t wp = node->write_pos;
                float* restrict dbuf = node->delay_buf;

                for (size_t i = 0; i < frames; ++i) {
                    uint32_t rp = (wp - delay_samples) & DELAY_MASK;
                    float delayed = dbuf[rp];
                    float x = out[i];
                    dbuf[wp] = x + (delayed * feedback);
                    out[i] = x + (delayed * 0.5f);
                    wp = (wp + 1) & DELAY_MASK;
                }
                node->write_pos = wp;
                break;
            }
            default:
                break;
        }
    }
    return 0;
}

int32_t dsp_analyze(const float* restrict buf, size_t frames, float* out_peak, float* out_rms, float* out_dc) {
    if (!buf || frames == 0) return -1;
    float peak = 0.0f;
    double sum_sq = 0.0;
    double sum_dc = 0.0;

    for (size_t i = 0; i < frames; ++i) {
        float x = buf[i];
        float ax = fabsf(x);
        if (ax > peak) peak = ax;
        sum_sq += (double)x * (double)x;
        sum_dc += (double)x;
    }

    if (out_peak) *out_peak = peak;
    if (out_rms)  *out_rms  = (float)sqrt(sum_sq / (double)frames);
    if (out_dc)   *out_dc   = (float)(sum_dc / (double)frames);
    return 0;
}