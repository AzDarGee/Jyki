# frozen_string_literal: true

# ============================================================================
# SAANSKARA STUDIO TELEMETRY (Zero-Gem Ruby + C Kernel/OS Introspection)
# ============================================================================
module SaanskaraTelemetry
  IS_MAC   = RbConfig::CONFIG["host_os"] =~ /darwin/i
  IS_LINUX = RbConfig::CONFIG["host_os"] =~ /linux/i
  PID      = Process.pid

  class << self
    # 1. Fast Process RAM (Resident Set Size in MB)
    # Uses /proc/self/statm on Linux (pure C kernel read, 0 spawns) or ps on macOS
    def ram_mb
      if IS_LINUX && File.exist?("/proc/self/statm")
        pages = File.read("/proc/self/statm").split[1].to_i
        (pages * 4096.0 / 1_048_576.0).round(2)
      else
        (`ps -o rss= -p #{PID}`.to_f / 1024.0).round(2)
      end
    rescue
      0.0
    end

    # 2. High-Resolution Process CPU Time (User + System in Seconds) via C getrusage()
    def cpu_times
      t = Process.times
      [t.utime, t.stime, t.utime + t.stime]
    end

    # 3. GPU Telemetry (macOS IOKit AGX/PerformanceStatistics or Linux DRM/nvidia-smi)
    # Cached for 3 seconds so it NEVER slows down HTTP requests!
    def gpu_summary
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if @gpu_cache && (now - @gpu_cache_at) < 3.0
        return @gpu_cache
      end

      @gpu_cache_at = now
      @gpu_cache = fetch_gpu_stats
    end

    private

    def fetch_gpu_stats
      if IS_MAC
        # Query macOS IOKit IOAccelerator PerformanceStatistics (Zero sudo required!)
        raw = `ioreg -r -d 1 -w 0 -c IOAccelerator 2>/dev/null`
        util = raw[/["'](?:Device Utilization %|GPU Activity\(%?\))["']\s*=\s*(\d+)/, 1]
        vram_bytes = raw[/["'](?:In use system memory|vramUsedBytes|Alloc system memory)["']\s*=\s*(\d+)/, 1]

        parts = []
        parts << "#{util}%" if util
        parts << "#{(vram_bytes.to_f / 1_048_576.0).round(1)}MB VRAM" if vram_bytes
        parts.empty? ? "Metal Idle" : parts.join(" • ")
      elsif IS_LINUX
        if system("which nvidia-smi > /dev/null 2>&1")
          out = `nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv,noheader,nounits 2>/dev/null`.strip
          out.empty? ? "GPU N/A" : "#{out.gsub(',', '% •')}MB VRAM"
        else
          "DRM/Integrated"
        end
      else
        "N/A"
      end
    rescue
      "N/A"
    end
  end

  # ==========================================================================
  # RACK MIDDLEWARE: Logs RAM, ΔRAM, CPU ms,CPU %, GC, and GPU per Request!
  # ==========================================================================
  class Middleware
    def initialize(app)
      @app = app
    end

    def call(env)
      # Skip noisy asset / healthcheck requests if desired
      path = env["PATH_INFO"].to_s
      return @app.call(env) if path.start_with?("/assets")

      ram_before = SaanskaraTelemetry.ram_mb
      u0, s0, total_cpu0 = SaanskaraTelemetry.cpu_times
      wall0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      status, headers, response = @app.call(env)

      wall_ms  = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - wall0) * 1000.0).round(2)
      u1, s1, total_cpu1 = SaanskaraTelemetry.cpu_times
      cpu_ms   = ((total_cpu1 - total_cpu0) * 1000.0).round(2)
      usr_ms   = ((u1 - u0) * 1000.0).round(2)
      sys_ms   = ((s1 - s0) * 1000.0).round(2)
      cpu_pct  = wall_ms > 0 ? ((cpu_ms / wall_ms) * 100.0).round(1) : 0.0

      ram_after = SaanskaraTelemetry.ram_mb
      ram_delta = (ram_after - ram_before).round(2)
      delta_str = ram_delta >= 0 ? "+#{ram_delta}MB" : "#{ram_delta}MB"

      gc_live = GC.stat(:heap_live_slots)
      gpu_str = SaanskaraTelemetry.gpu_summary

      msg = "\e[38;5;214m📊 [Saanskara Telemetry]\e[0m " \
        "RAM: \e[1m#{ram_after}MB\e[0m (Δ #{delta_str}) | " \
        "CPU: \e[1m#{cpu_ms}ms\e[0m (usr:#{usr_ms}ms sys:#{sys_ms}ms • #{cpu_pct}%) | " \
        "Wall: #{wall_ms}ms | " \
        "GPU: \e[36m#{gpu_str}\e[0m | " \
        "GC Slots: #{gc_live}"

      Rails.logger.info(msg)
      # Also print directly to STDOUT in dev so you always see it in `bin/dev`!
      $stdout.puts(msg) if Rails.env.development?

      [status, headers, response]
    end
  end
end

# Register the Middleware in the Rails stack
Rails.application.config.middleware.insert_before(Rails::Rack::Logger, SaanskaraTelemetry::Middleware)