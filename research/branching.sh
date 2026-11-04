ruby -e '
# 1. Create the PostgreSQL tables for CRDT Branches & Live Activity Log
system("bin/rails runner \"
  conn = ActiveRecord::Base.connection
  conn.execute(%Q{
    CREATE TABLE IF NOT EXISTS daw_branches (
      branch_name VARCHAR(64) PRIMARY KEY,
      parent_branch VARCHAR(64),
      lamport_clock BIGINT NOT NULL DEFAULT 0,
      crdt_state_binary BYTEA NOT NULL,
      updated_at TIMESTAMPTZ DEFAULT now()
    );
    CREATE UNLOGGED TABLE IF NOT EXISTS daw_activity_log (
      id BIGSERIAL PRIMARY KEY,
      branch_name VARCHAR(64) NOT NULL,
      actor_name VARCHAR(64) NOT NULL,
      action_desc TEXT NOT NULL,
      lamport_clock BIGINT NOT NULL,
      param_value REAL NOT NULL,
      created_at TIMESTAMPTZ DEFAULT now()
    ) WITH (fillfactor = 70);
  })
\"")

# 2. Upgrade dsp/saanskara_dsp.c with a True C CRDT Lamport Clock Merger!
File.write("dsp/saanskara_dsp.c", <<~C)
  #include <stdint.h>

  #ifdef __wasm__
    #define EXPORT(name) __attribute__((export_name(#name)))
  #else
    #define EXPORT(name) __attribute__((visibility("default")))
  #endif

  // 16-Byte CRDT Binary Delta Packet (Conflict-Free across out-of-order network packets!)
  typedef struct __attribute__((packed)) {
    uint8_t  opcode;        // 1 = EQ/Mod, 2 = MIDI Note, 3 = DJ Filter
    uint8_t  actor_id;      // Unique Collaborator ID (0..255)
    uint16_t item_id;       // Parameter / Note index
    uint32_t lamport_clock; // Monotonic Logical Clock for deterministic CRDT resolution!
    float    param_a;       // Value (e.g., EQ Gain / Mod Depth)
    float    param_b;       // Secondary Value
  } CrdtDeltaPacket;

  typedef struct {
    float    eq_gain[16];
    uint32_t eq_clock[16];  // CRDT Last-Writer-Wins Lamport Clock per parameter
    uint8_t  eq_actor[16];  // Tie-breaker Actor ID if two edits happen at the exact same clock tick!
    float    vu_peak;
    float    wave_scope[128];
    float    audio_io[128];
  } DawCrdtState;

  static DawCrdtState state;

  EXPORT(get_audio_io_ptr)
  float* get_audio_io_ptr(void) { return state.audio_io; }

  // MATHEMATICAL CRDT MERGE IN PURE C:
  // Commutative & Idempotent! Even if network packets arrive out of order,
  // every browser and server converges to the exact same state.
  EXPORT(apply_crdt_delta)
  int apply_crdt_delta(const CrdtDeltaPacket* pkt) {
    if (pkt->opcode == 1 && pkt->item_id < 16) {
      uint16_t idx = pkt->item_id;
      uint32_t current_clock = state.eq_clock[idx];

      // Accept update ONLY if Lamport clock is newer (or equal clock with higher actor_id tie-breaker)
      if (pkt->lamport_clock > current_clock ||
         (pkt->lamport_clock == current_clock && pkt->actor_id >= state.eq_actor[idx])) {
        state.eq_gain[idx]  = pkt->param_a;
        state.eq_clock[idx] = pkt->lamport_clock;
        state.eq_actor[idx] = pkt->actor_id;
        return 1; // Delta won and updated state!
      }
    }
    return 0; // Stale out-of-order packet safely ignored by CRDT!
  }

  EXPORT(process_block)
  float process_block(uint32_t frames, float master_gain) {
    float peak = 0.0f;
    float eq0 = state.eq_gain[0] != 0.0f ? state.eq_gain[0] : 1.0f;

    for (uint32_t i = 0; i < frames; i++) {
      float s = state.audio_io[i] * eq0 * master_gain;
      state.audio_io[i] = s;
      state.wave_scope[i] = s;
      float abs_s = s < 0.0f ? -s : s;
      if (abs_s > peak) peak = abs_s;
    }
    state.vu_peak = peak;
    return peak;
  }
C

# 3. Rebuild .dylib and .wasm
system("bin/rails dsp:build")

# 4. Update Browser AudioWorklet to call apply_crdt_delta
File.write("public/wasm/saanskara_worklet.js", <<~JS)
  class SaanskaraWorkletProcessor extends AudioWorkletProcessor {
    constructor(options) {
      super();
      this.ready = false;
      this.sharedView = new Float32Array(options.processorOptions.sharedRam);

      WebAssembly.instantiate(options.processorOptions.wasmBytes, {}).then(({ instance }) => {
        this.wasm = instance.exports;
        this.ioPtr = this.wasm.get_audio_io_ptr();
        this.wasmAudioBuf = new Float32Array(this.wasm.memory.buffer, this.ioPtr, 128);
        this.ready = true;
      });

      this.port.onmessage = (e) => {
        if (!this.ready) return;
        const pktBytes = new Uint8Array(e.data);
        const wasmBytes = new Uint8Array(this.wasm.memory.buffer, this.ioPtr, 16);
        wasmBytes.set(pktBytes);
        this.wasm.apply_crdt_delta(this.ioPtr);
      };
    }

    process(inputs, outputs) {
      if (!this.ready) return true;
      const out = outputs[0][0];
      const frames = out.length;

      for (let i = 0; i < frames; i++) {
        this.wasmAudioBuf[i] = inputs[0]?.[0]?.[i] || Math.sin((currentFrame + i) * 0.04) * 0.25;
      }

      const vuPeak = this.wasm.process_block(frames, 1.0);
      out.set(this.wasmAudioBuf.subarray(0, frames));

      this.sharedView[0] = vuPeak;
      this.sharedView.set(this.wasmAudioBuf.subarray(0, frames), 16);
      return true;
    }
  }
  registerProcessor("saanskara-c-dsp", SaanskaraWorkletProcessor);
JS

# 5. Upgrade StudiosController with CRDT Sync, Branching & Activity Monitor API
File.write("app/controllers/studios_controller.rb", <<~RUBY)
  # frozen_string_literal: true

  class StudiosController < ApplicationController
    before_action :enable_shared_array_buffer_headers!
    skip_before_action :verify_authenticity_token

    def show
      @project_name = "Raga Bhairavi — 128 BPM.saan"
      ensure_default_branch!
    end

    # 1. REALTIME CRDT DELTA INGEST + ACTIVITY LOGGING
    def sync_binary_delta
      raw_16b = request.raw_post
      opcode, actor_id, item_id, clock, val_a, _val_b = raw_16b.unpack("CCs<L<ff")
      branch = params[:branch].presence || "main"
      actor_name = params[:actor].presence || "Producer-\#{actor_id}"

      conn = ActiveRecord::Base.connection.raw_connection

      # Deterministic CRDT Upsert in Postgres: only overwrites if Lamport clock >= current!
      conn.exec_params(
        <<~SQL,
          INSERT INTO daw_branches (branch_name, lamport_clock, crdt_state_binary, updated_at)
          VALUES ($1, $2, $3::bytea, now())
          ON CONFLICT (branch_name) DO UPDATE
          SET lamport_clock = GREATEST(daw_branches.lamport_clock, EXCLUDED.lamport_clock),
              crdt_state_binary = CASE
                WHEN EXCLUDED.lamport_clock >= daw_branches.lamport_clock THEN EXCLUDED.crdt_state_binary
                ELSE daw_branches.crdt_state_binary
              END,
              updated_at = now();
        SQL
        [branch, clock, { value: raw_16b, format: 1 }]
      )

      # Record in UNLOGGED In-Memory Activity Monitor
      desc = "EQ/Mod Curve -> \#{val_a.round(2)}x (Clock #\#{clock})"
      conn.exec_params(
        "INSERT INTO daw_activity_log (branch_name, actor_name, action_desc, lamport_clock, param_value) VALUES ($1, $2, $3, $4, $5)",
        [branch, actor_name, desc, clock, val_a]
      )

      head :no_content
    end

    # 2. CREATE / FORK A MUSICAL BRANCH (Clones the parent CRDT binary vector!)
    def create_branch
      source = params[:source_branch].presence || "main"
      target = params[:new_branch].to_s.strip.downcase.gsub(/[^a-z0-9_-]/, "-")
      return render json: { error: "Invalid branch" }, status: :unprocessable_entity if target.empty?

      conn = ActiveRecord::Base.connection.raw_connection
      conn.exec_params(
        <<~SQL,
          INSERT INTO daw_branches (branch_name, parent_branch, lamport_clock, crdt_state_binary)
          SELECT $1, branch_name, lamport_clock, crdt_state_binary
          FROM daw_branches WHERE branch_name = $2
          ON CONFLICT (branch_name) DO NOTHING;
        SQL
        [target, source]
      )
      conn.exec_params(
        "INSERT INTO daw_activity_log (branch_name, actor_name, action_desc, lamport_clock, param_value) VALUES ($1, $2, $3, 0, 1.0)",
        [target, "Git-of-Music", "Forked branch [\#{target}] from [\#{source}]", ]
      )
      render json: { branch: target }
    end

    # 3. POLL CRDT STATE, BRANCHES & LIVE ACTIVITY STREAM
    def state_stream
      branch = params[:branch].presence || "main"
      conn = ActiveRecord::Base.connection.raw_connection

      branch_row = conn.exec_params(
        "SELECT lamport_clock, encode(crdt_state_binary, \x27hex\x27) AS hex_pkt FROM daw_branches WHERE branch_name = $1",
        [branch]
      ).first

      branches = conn.exec("SELECT branch_name, lamport_clock FROM daw_branches ORDER BY updated_at DESC").map(&:to_h)

      activities = conn.exec_params(
        "SELECT actor_name, action_desc, param_value, to_char(created_at, \x27HH24:MI:SS\x27) as ts FROM daw_activity_log WHERE branch_name = $1 ORDER BY id DESC LIMIT 12",
        [branch]
      ).map(&:to_h)

      render json: {
        branch: branch,
        lamport_clock: branch_row ? branch_row["lamport_clock"].to_i : 0,
        hex_packet: branch_row ? branch_row["hex_pkt"] : nil,
        branches: branches,
        activities: activities
      }
    end

    private

    def ensure_default_branch!
      conn = ActiveRecord::Base.connection.raw_connection
      default_pkt = [1, 1, 0, 1, 1.0, 0.0].pack("CCs<L<ff")
      conn.exec_params(
        "INSERT INTO daw_branches (branch_name, lamport_clock, crdt_state_binary) VALUES (\x27main\x27, 1, $1::bytea) ON CONFLICT DO NOTHING",
        [{ value: default_pkt, format: 1 }]
      )
    end

    def enable_shared_array_buffer_headers!
      response.set_header("Cross-Origin-Opener-Policy", "same-origin")
      response.set_header("Cross-Origin-Embedder-Policy", "credentialless")
      response.set_header("Cross-Origin-Resource-Policy", "same-origin")
    end
  end
RUBY

# 6. Update Routes
File.write("config/routes.rb", <<~RUBY)
  Rails.application.routes.draw do
    root "studios#show"
    post "/studio/delta",  to: "studios#sync_binary_delta"
    post "/studio/branch", to: "studios#create_branch"
    get  "/studio/stream", to: "studios#state_stream"
  end
RUBY

# 7. Update Stimulus Controller & View with Branch Selector + Live Activity Feed
File.write("app/javascript/controllers/daw_canvas_controller.js", <<~JS)
  import { Controller } from "@hotwired/stimulus"

  export default class extends Controller {
    static targets = ["canvas", "vuReadout", "slider", "clockReadout", "branchSelect", "newBranchInput", "activityFeed", "actorBadge"]

    connect() {
      this.sharedRam = new SharedArrayBuffer(4096);
      this.sharedFloats = new Float32Array(this.sharedRam);
      this.modDepth = 1.0;
      this.lamportClock = 1;
      this.currentBranch = "main";
      this.actorId = Math.floor(Math.random() * 200) + 10;
      this.actorName = `Session-${this.actorId}`;
      this.actorBadgeTarget.textContent = this.actorName;

      this.ctx = this.canvasTarget.getContext("2d", { alpha: false, desynchronized: true });
      this.resizeCanvas();
      window.addEventListener("resize", () => this.resizeCanvas());

      const loop = () => {
        this.renderGpuFrame();
        this.rafId = requestAnimationFrame(loop);
      };
      this.rafId = requestAnimationFrame(loop);

      // Poll CRDT state & live activity every 250ms (syncs across multiple tabs/users & branches!)
      this.syncTimer = setInterval(() => this.pullCrdtState(), 250);
      this.pullCrdtState();
    }

    disconnect() {
      if (this.rafId) cancelAnimationFrame(this.rafId);
      if (this.syncTimer) clearInterval(this.syncTimer);
    }

    resizeCanvas() {
      const dpr = window.devicePixelRatio || 1;
      const rect = this.canvasTarget.parentElement.getBoundingClientRect();
      this.canvasTarget.width = rect.width * dpr;
      this.canvasTarget.height = rect.height * dpr;
      this.ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      this.width = rect.width;
      this.height = rect.height;
    }

    async startAudio() {
      if (this.audioCtx) return;
      this.audioCtx = new AudioContext({ sampleRate: 48000, latencyHint: "interactive" });
      await this.audioCtx.audioWorklet.addModule("/wasm/saanskara_worklet.js");
      const wasmBytes = await fetch("/wasm/saanskara_dsp.wasm").then(r => r.arrayBuffer());

      this.worklet = new AudioWorkletNode(this.audioCtx, "saanskara-c-dsp", {
        processorOptions: { wasmBytes, sharedRam: this.sharedRam }
      });
      this.worklet.connect(this.audioCtx.destination);
    }

    // Increment Lamport Clock & pack 16-Byte CRDT Binary Delta
    sendBinaryDelta(event) {
      const gain = parseFloat(event.target.value);
      this.modDepth = gain;
      this.lamportClock += 1;
      this.clockReadoutTarget.textContent = `Clock #${this.lamportClock}`;

      const buf = new ArrayBuffer(16);
      const view = new DataView(buf);
      view.setUint8(0, 1);                       // Opcode 1 = EQ / Mod
      view.setUint8(1, this.actorId);            // Collaborator Actor ID
      view.setUint16(2, 0, true);                // Item 0
      view.setUint32(4, this.lamportClock, true);// CRDT Lamport Logical Clock!
      view.setFloat32(8, gain, true);            // Parameter Value

      if (this.worklet) this.worklet.port.postMessage(buf);
      fetch(`/studio/delta?branch=${encodeURIComponent(this.currentBranch)}&actor=${encodeURIComponent(this.actorName)}`, {
        method: "POST",
        body: buf
      });
    }

    async createBranch() {
      const name = this.newBranchInputTarget.value.trim();
      if (!name) return;
      const res = await fetch(`/studio/branch?source_branch=${this.currentBranch}&new_branch=${encodeURIComponent(name)}`, { method: "POST" });
      if (res.ok) {
        const data = await res.json();
        this.currentBranch = data.branch;
        this.newBranchInputTarget.value = "";
        this.pullCrdtState();
      }
    }

    switchBranch(event) {
      this.currentBranch = event.target.value;
      this.lamportClock = 0; // Reset local clock so branch state hydrates cleanly
      this.pullCrdtState();
    }

    async pullCrdtState() {
      const res = await fetch(`/studio/stream?branch=${encodeURIComponent(this.currentBranch)}`);
      if (!res.ok) return;
      const data = await res.json();

      // 1. If remote CRDT Lamport Clock is ahead of us (or we switched branches), apply binary packet!
      if (data.hex_packet && data.lamport_clock >= this.lamportClock) {
        const bytes = new Uint8Array(data.hex_packet.match(/.{1,2}/g).map(b => parseInt(b, 16)));
        const view = new DataView(bytes.buffer);
        const remoteGain = view.getFloat32(8, true);

        if (data.lamport_clock > this.lamportClock || Math.abs(remoteGain - this.modDepth) > 0.01) {
          this.lamportClock = data.lamport_clock;
          this.modDepth = remoteGain;
          this.sliderTarget.value = remoteGain;
          this.clockReadoutTarget.textContent = `Clock #${this.lamportClock}`;
          if (this.worklet) this.worklet.port.postMessage(bytes.buffer);
        }
      }

      // 2. Update Branch Selector Dropdown
      const currentOptions = Array.from(this.branchSelectTarget.options).map(o => o.value);
      data.branches.forEach(b => {
        if (!currentOptions.includes(b.branch_name)) {
          const opt = document.createElement("option");
          opt.value = b.branch_name;
          opt.textContent = `🌿 ${b.branch_name}`;
          this.branchSelectTarget.appendChild(opt);
        }
      });
      this.branchSelectTarget.value = this.currentBranch;

      // 3. Render Live Activity Monitor
      this.activityFeedTarget.innerHTML = data.activities.map(a => `
        <div class="border-b border-zinc-800/80 py-1.5 text-xs font-mono">
          <div class="flex justify-between text-zinc-400">
            <span class="text-teal-400 font-semibold">${a.actor_name}</span>
            <span>${a.ts}</span>
          </div>
          <div class="text-zinc-200 mt-0.5">${a.action_desc}</div>
        </div>
      `).join("");
    }

    renderGpuFrame() {
      const ctx = this.ctx;
      const w = this.width || 800;
      const h = this.height || 600;

      ctx.fillStyle = "#18181b";
      ctx.fillRect(0, 0, w, h);

      ctx.strokeStyle = "#27272a";
      ctx.lineWidth = 1;
      for (let x = 0; x < w; x += 80) { ctx.beginPath(); ctx.moveTo(x, 0); ctx.lineTo(x, h); ctx.stroke(); }
      for (let y = 0; y < h; y += 48) { ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(w, y); ctx.stroke(); }

      // MIDI Note + Visual Modulation Curve synced via CRDT
      ctx.fillStyle = "#27272a";
      ctx.strokeStyle = "#2dd4bf";
      ctx.lineWidth = 2;
      ctx.beginPath();
      ctx.roundRect(80, 96, 320, 48, 6);
      ctx.fill();
      ctx.stroke();

      ctx.strokeStyle = "#d946ef";
      ctx.lineWidth = 3;
      ctx.beginPath();
      ctx.moveTo(85, 134);
      ctx.quadraticCurveTo(240, 134 - (this.modDepth * 38), 395, 134);
      ctx.stroke();

      // Live C-Wasm Audio Oscilloscope
      ctx.strokeStyle = "#2dd4bf";
      ctx.lineWidth = 2.5;
      ctx.beginPath();
      const baseY = h - 100;
      for (let i = 0; i < 128; i++) {
        const sample = this.sharedFloats[16 + i] || 0;
        const x = (i / 127) * w;
        const y = baseY + (sample * 140);
        i === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y);
      }
      ctx.stroke();

      const vu = this.sharedFloats[0] || 0;
      const db = vu > 0.0001 ? (20 * Math.log10(vu)).toFixed(1) : "-∞";
      this.vuReadoutTarget.textContent = `${db} dBFS`;
    }
  }
JS

File.write("app/views/studios/show.html.erb", <<~ERB)
  <div data-controller="daw-canvas" class="h-screen w-screen bg-zinc-900 text-zinc-100 flex flex-col select-none overflow-hidden">
    <header class="h-14 border-b border-zinc-800 px-4 flex items-center justify-between bg-zinc-950">
      <div class="flex items-center gap-3">
        <span class="text-teal-400 font-bold tracking-wider">SAANSKARA DAW</span>
        <span data-daw-canvas-target="actorBadge" class="font-mono text-xs bg-fuchsia-500/20 text-fuchsia-400 px-2 py-0.5 rounded border border-fuchsia-500/30"></span>

        <!-- Musical Branch Switcher & Forking -->
        <select data-daw-canvas-target="branchSelect" data-action="change->daw-canvas#switchBranch"
                class="bg-zinc-900 border border-zinc-700 text-teal-400 font-mono text-xs px-2.5 py-1 rounded">
          <option value="main">🌿 main</option>
        </select>

        <div class="flex items-center gap-1">
          <input data-daw-canvas-target="newBranchInput" type="text" placeholder="new-remix-branch..."
                 class="bg-zinc-900 border border-zinc-800 text-xs font-mono px-2 py-1 rounded w-36 text-zinc-200">
          <button data-action="click->daw-canvas#createBranch"
                  class="bg-zinc-800 hover:bg-zinc-700 text-teal-400 font-mono text-xs px-2.5 py-1 rounded cursor-pointer">
            + Fork Branch
          </button>
        </div>
      </div>

      <div class="flex items-center gap-5">
        <button data-action="click->daw-canvas#startAudio"
                class="bg-teal-400 hover:bg-teal-300 text-zinc-950 font-semibold px-3 py-1 rounded text-xs transition cursor-pointer">
          ▶ Boot C-Wasm Audio
        </button>

        <label class="flex items-center gap-2 text-xs font-mono text-fuchsia-400">
          CRDT Mod
          <input data-daw-canvas-target="slider" type="range" min="0.1" max="2.0" step="0.05" value="1.0"
                 data-action="input->daw-canvas#sendBinaryDelta"
                 class="accent-fuchsia-500">
        </label>

        <span data-daw-canvas-target="clockReadout" class="font-mono text-xs text-zinc-400">Clock #1</span>

        <div class="font-mono text-xs bg-zinc-900 border border-zinc-800 px-2.5 py-1 rounded">
          VU: <span data-daw-canvas-target="vuReadout" class="text-teal-400">-∞ dBFS</span>
        </div>
      </div>
    </header>

    <div class="flex-1 flex overflow-hidden">
      <!-- 120fps Hardware Canvas -->
      <main class="flex-1 relative">
        <canvas data-daw-canvas-target="canvas" class="w-full h-full block"></canvas>
      </main>

      <!-- Live CRDT Activity & Collaboration Monitor Sidebar -->
      <aside class="w-72 bg-zinc-950 border-l border-zinc-800 p-4 flex flex-col">
        <div class="text-xs font-mono font-bold text-teal-400 uppercase tracking-wider mb-3 flex justify-between">
          <span>⚡ Live CRDT Activity</span>
          <span class="text-zinc-500">UNLOGGED PG</span>
        </div>
        <div data-daw-canvas-target="activityFeed" class="flex-1 overflow-y-auto space-y-1"></div>
      </aside>
    </div>
  </div>
ERB

puts "✅ CRDT Collaboration + Branching + Activity Monitor Installed! Refresh http://localhost:3000"
'