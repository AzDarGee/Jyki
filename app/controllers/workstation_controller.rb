# frozen_string_literal: true

class WorkstationController < ApplicationController
  before_action :set_isolation_headers
  before_action :load_workstation_state, only: [ :index ]

  def index
  end

  def create_track
    track_params = params.expect(track: [ :kind, :name ])
    kind = track_params[:kind].to_s.downcase
    kind = "audio" unless [ "audio", "midi", "bus" ].include?(kind)

    next_index = (params[:current_count] || 5).to_i
    formatted_num = format("%02d", next_index)

    default_names = {
      "audio" => "Audio Stem #{next_index}",
      "midi" => "Synth Lead #{next_index}",
      "bus" => "Aux Group #{next_index}"
    }
    badge_map = { "audio" => "AUDIO", "midi" => "MIDI", "bus" => "BUS" }

    @new_track = {
      id: next_index,
      number: formatted_num,
      name: track_params[:name].presence || "#{formatted_num}. #{default_names[kind]}",
      short_name: track_params[:name].presence || "#{formatted_num}. #{default_names[kind]}",
      kind: kind,
      badge: badge_map[kind],
      gain_db: 0.0,
      pan: 0,
      muted: false,
      soloed: false,
      armed: false,
      nr: kind == "audio",
      fx_active: 1,
      fx_total: 4,
      mode_badge: kind == "audio" ? "NR ON" : "DIRECT",
      clips: []
    }

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.append(
            "track_headers_list",
            partial: "workstation/track_header_row",
            locals: { track: @new_track }
          ),
          turbo_stream.append(
            "mixer_channels_list",
            partial: "workstation/mixer_channel_card",
            locals: { track: @new_track }
          )
        ]
      end
      format.json { render json: { status: "ok", track: @new_track }, status: :created }
    end
  end

  def update_mixer
    mixer_params = params.expect(mixer: [ :track_id, :gain_db, :pan, :muted, :soloed, :armed, :nr ])

    respond_to do |format|
      format.json do
        render json: {
          status: "synced",
          engine: "wasm_dsp_arena",
          telemetry: mixer_params.to_h
        }
      end
      format.turbo_stream { head :ok }
    end
  end

  def ai_analysis
    analysis_params = params.expect(ai: [ :prompt, :mode ])
    @analysis_result = {
      mode: analysis_params[:mode] || "Mix Critic",
      model: "gemini-4-argon",
      summary: "Phase coherence 98.4% between Track 01 (Sub Bass 808) and Track 03 (Granular Texture). Suggested -2.1 dB dynamic dip at 62 Hz (Q=3.2) on Granular Pad sidechain."
    }

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.update(
          "ai_lab_response",
          partial: "workstation/ai_lab_response",
          locals: { result: @analysis_result }
        )
      end
      format.json { render json: @analysis_result }
    end
  end

  private

    def set_isolation_headers
      response.set_header("Cross-Origin-Opener-Policy", "same-origin")
      response.set_header("Cross-Origin-Embedder-Policy", "credentialless")
      response.set_header("Cross-Origin-Resource-Policy", "same-origin")
    end

    def load_workstation_state
      @transport = {
        bpm: 128,
        position: "1.1",
        sample_rate: "48.0 kHz",
        bit_depth: "24-bit",
        low_latency: true,
        crdt_status: "CRDT Ready",
        lufs: "-∞ LUFS"
      }

      @library_items = [
        {
          id: "sample-808",
          title: "Saanskara 808 Sub C1.wav",
          subtitle: "Sample Pack · 96kHz/24-bit",
          category: "library",
          kind: "audio",
          bpm: 128,
          active: true
        },
        {
          id: "vst-buchla",
          title: "Buchla West Coast Pluck.vstpreset",
          subtitle: "VST3 Patch · Synth",
          category: "library",
          kind: "midi",
          bpm: 128,
          active: false
        },
        {
          id: "au-tape",
          title: "Tape Saturator Master Chain.aupreset",
          subtitle: "AU Rack · Mastering",
          category: "library",
          kind: "bus",
          bpm: 128,
          active: false
        },
        {
          id: "flac-break",
          title: "Modular Breakbeat 128bpm.flac",
          subtitle: "Loop Stem · Lossless",
          category: "library",
          kind: "audio",
          bpm: 128,
          active: false
        },
        {
          id: "user-tanpura",
          title: "Custom Raga Bhairav Drone.wav",
          subtitle: "My Samples · 96kHz/32-bit Float",
          category: "my_samples",
          kind: "audio",
          bpm: 128,
          active: false
        },
        {
          id: "user-tabla",
          title: "Live Tabla Transient Chop 128.wav",
          subtitle: "My Samples · Close Ribbon Mic",
          category: "my_samples",
          kind: "audio",
          bpm: 128,
          active: false
        }
      ]

      @tracks = [
        {
          id: 1,
          number: "01",
          name: "01. Sub Bass 808",
          short_name: "01. Sub Bass 808",
          mixer_name: "01. Sub Bass 808",
          kind: "audio",
          badge: "AUDIO",
          gain_db: -1.1,
          pan: 0,
          muted: false,
          soloed: false,
          armed: true,
          nr: true,
          selected: true,
          fx_active: 4,
          fx_total: 4,
          mode_badge: "NR ON",
          clips: [
            { title: "808 SUB GLIDE A", start_bar: 1.0, length_bars: 2.0, color: "cyan" },
            { title: "808 SUB GLIDE B", start_bar: 3.0, length_bars: 2.0, color: "cyan" },
            { title: "808 DROP PEAK", start_bar: 5.0, length_bars: 3.0, color: "cyan" }
          ]
        },
        {
          id: 2,
          number: "02",
          name: "02. Prophet-6 Poly Synth",
          short_name: "02. Prophet-6 Po...",
          mixer_name: "02. Prophet-6 Poly ...",
          kind: "midi",
          badge: "MIDI",
          gain_db: -2.4,
          pan: -18,
          muted: false,
          soloed: false,
          armed: false,
          nr: false,
          selected: false,
          fx_active: 2,
          fx_total: 3,
          mode_badge: "DIRECT",
          clips: [
            { title: "MIDI ARP PATTERN 01", start_bar: 1.0, length_bars: 4.0, color: "amber" },
            { title: "MIDI COUNTER LEAD", start_bar: 5.0, length_bars: 3.0, color: "amber" }
          ]
        },
        {
          id: 3,
          number: "03",
          name: "03. Granular Texture Pad",
          short_name: "03. Granular Text...",
          mixer_name: "03. Granular Textu...",
          kind: "audio",
          badge: "AUDIO",
          gain_db: -2.9,
          pan: 22,
          muted: false,
          soloed: false,
          armed: false,
          nr: true,
          selected: false,
          fx_active: 3,
          fx_total: 3,
          mode_badge: "NR ON",
          clips: [
            { title: "ATMOS FOIL STEM", start_bar: 2.0, length_bars: 3.0, color: "teal" },
            { title: "VOCAL RESAMPLE GRAIN", start_bar: 5.0, length_bars: 3.0, color: "teal" }
          ]
        },
        {
          id: 4,
          number: "04",
          name: "04. Analog Drum Bus",
          short_name: "04. Analog Drum ...",
          mixer_name: "04. Analog Drum Bus",
          kind: "bus",
          badge: "BUS",
          gain_db: -0.7,
          pan: 0,
          muted: false,
          soloed: false,
          armed: false,
          nr: false,
          selected: false,
          fx_active: 2,
          fx_total: 2,
          mode_badge: "DIRECT",
          clips: [
            { title: "BREAKBEAT TRANSIENT LOOP", start_bar: 1.0, length_bars: 7.0, color: "terracotta" }
          ]
        }
      ]

      @inserts = [
        { slot: 1, name: "Saanskara Sp...", full_name: "Saanskara Spanda EQ", type: "Stock DSP", cpu: "1.2%", active: true },
        { slot: 2, name: "Saanskara Ta...", full_name: "Saanskara Tape Saturator", type: "Stock DSP", cpu: "0.8%", active: true },
        { slot: 3, name: "FabFilter Pro-C 2 D...", full_name: "FabFilter Pro-C 2 Drum", type: "VST3", cpu: "2.4%", active: true },
        { slot: 4, name: "Saanskara Sp...", full_name: "Saanskara Spatial Sub", type: "Stock DSP", cpu: "1.5%", active: true }
      ]
    end
end

