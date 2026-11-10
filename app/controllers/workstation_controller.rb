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

    collapsed = ActiveModel::Type::Boolean.new.cast(params[:collapsed])

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.append(
            "track_headers_list",
            partial: "workstation/track_header_row",
            locals: { track: @new_track, collapsed: collapsed }
          ),
          turbo_stream.append(
            "mixer_channels_list",
            partial: "workstation/mixer_channel_card",
            locals: { track: @new_track }
          )
        ]
      end
      format.json { render json: { status: "ok", track: @new_track, collapsed: collapsed }, status: :created }
    end
  end

  def destroy_track
    track_id = params[:id].to_i

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.remove("track_header_row_#{track_id}"),
          turbo_stream.remove("mixer_channel_card_#{track_id}"),
          turbo_stream.remove("ideas_track_column_#{track_id}")
        ]
      end
      format.json { render json: { status: "ok", track_id: track_id }, status: :ok }
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

      @decks = [
        {
          id: "A",
          letter: "A",
          key_camelot: "8A",
          key_musical: "Am",
          status_badge: "👑 MASTER",
          status_kind: "master",
          title: "Saanskara Dubplate (VIP Mix)",
          artist: "Kora & Sub-Zero",
          bpm: 128.00,
          pitch: "+0.0%",
          color_hex: "#c28e5c",
          accent_hex: "#d97706",
          progress_pct: 62,
          is_master: true,
          synced: true,
          halftime: false
        },
        {
          id: "B",
          letter: "B",
          key_camelot: "9A",
          key_musical: "Em",
          status_badge: "KEY OK",
          status_kind: "ok",
          title: "Obsidian Warehouse Tool",
          artist: "Vortex Modular",
          bpm: 126.00,
          pitch: "+0.0%",
          color_hex: "#14b8a6",
          accent_hex: "#06b6d4",
          progress_pct: 54,
          is_master: false,
          synced: false,
          halftime: false
        },
        {
          id: "C",
          letter: "C",
          key_camelot: "7A",
          key_musical: "Dm",
          status_badge: "KEY OK",
          status_kind: "ok",
          title: "Granular Fog Loop",
          artist: "Aria Voss",
          bpm: 124.00,
          pitch: "+0.0%",
          color_hex: "#a86464",
          accent_hex: "#b87365",
          progress_pct: 48,
          is_master: false,
          synced: false,
          halftime: false
        },
        {
          id: "D",
          letter: "D",
          key_camelot: "8B",
          key_musical: "C",
          status_badge: "KEY OK",
          status_kind: "ok",
          title: "Neon Drift (Peak Hour)",
          artist: "Helix Unit",
          bpm: 130.00,
          pitch: "+0.0%",
          color_hex: "#c85a28",
          accent_hex: "#ea580c",
          progress_pct: 70,
          is_master: false,
          synced: false,
          halftime: false
        },
        {
          id: "E",
          letter: "E",
          key_camelot: "5A",
          key_musical: "Cm",
          status_badge: "KEY CLASH",
          status_kind: "clash",
          title: "Rust Belt Percussion",
          artist: "Tomas Reyes",
          bpm: 132.00,
          pitch: "+0.0%",
          color_hex: "#5c7a72",
          accent_hex: "#64827a",
          progress_pct: 42,
          is_master: false,
          synced: false,
          halftime: false
        },
        {
          id: "F",
          letter: "F",
          key_camelot: "8A",
          key_musical: "Am",
          status_badge: "KEY MATCH",
          status_kind: "match",
          title: "Halftime Sub Ritual",
          artist: "Moss & Ember",
          bpm: 64.00,
          pitch: "+0.0%",
          color_hex: "#b58952",
          accent_hex: "#ca8a04",
          progress_pct: 58,
          is_master: false,
          synced: false,
          halftime: true
        }
      ]

      @chat_messages = StudioChatMessage.default_messages_for("project_room")
      @crdt_branches = CrdtBranch.default_branches
    end
end
