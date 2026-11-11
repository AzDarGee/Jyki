# frozen_string_literal: true

class WorkstationController < ApplicationController
  before_action :set_isolation_headers
  before_action :load_workstation_state, only: [ :index ]

  WORKSTATION_PROJECT_NAME = "Jaku Workstation Session"

  DEFAULT_WORKSTATION_TRACKS = [
    {
      name: "01. Sub Bass 808",
      short_name: "01. Sub Bass 808",
      mixer_name: "01. Sub Bass 808",
      track_type: "audio",
      position: 0,
      color_hex: "#14b8a6",
      volume_db: -1.1,
      pan: 0.0,
      muted: false,
      soloed: false,
      armed: true,
      nr: true,
      fx_active: 4,
      fx_total: 4,
      wave_style: "sub808",
      clips: [
        { title: "808 SUB GLIDE A", start_bar: 1.0, length_bars: 2.0, color: "cyan" },
        { title: "808 SUB GLIDE B", start_bar: 3.0, length_bars: 2.0, color: "cyan" },
        { title: "808 DROP PEAK", start_bar: 5.0, length_bars: 3.0, color: "cyan" }
      ]
    },
    {
      name: "02. Prophet-6 Poly Synth",
      short_name: "02. Prophet-6 Po...",
      mixer_name: "02. Prophet-6 Poly ...",
      track_type: "midi",
      position: 1,
      color_hex: "#f59e0b",
      volume_db: -2.4,
      pan: -0.36,
      muted: false,
      soloed: false,
      armed: false,
      nr: false,
      fx_active: 2,
      fx_total: 3,
      wave_style: "midiArp",
      clips: [
        { title: "MIDI ARP PATTERN 01", start_bar: 1.0, length_bars: 4.0, color: "amber" },
        { title: "MIDI COUNTER LEAD", start_bar: 5.0, length_bars: 3.0, color: "amber" }
      ]
    },
    {
      name: "03. Granular Texture Pad",
      short_name: "03. Granular Text...",
      mixer_name: "03. Granular Textu...",
      track_type: "audio",
      position: 2,
      color_hex: "#2dd4bf",
      volume_db: -2.9,
      pan: 0.44,
      muted: false,
      soloed: false,
      armed: false,
      nr: true,
      fx_active: 3,
      fx_total: 3,
      wave_style: "granular",
      clips: [
        { title: "ATMOS FOIL STEM", start_bar: 2.0, length_bars: 3.0, color: "teal" },
        { title: "VOCAL RESAMPLE GRAIN", start_bar: 5.0, length_bars: 3.0, color: "teal" }
      ]
    },
    {
      name: "04. Analog Drum Bus",
      short_name: "04. Analog Drum ...",
      mixer_name: "04. Analog Drum Bus",
      track_type: "bus",
      position: 3,
      color_hex: "#ea580c",
      volume_db: -0.7,
      pan: 0.0,
      muted: false,
      soloed: false,
      armed: false,
      nr: false,
      fx_active: 2,
      fx_total: 2,
      wave_style: "drumBus",
      clips: [
        { title: "BREAKBEAT TRANSIENT LOOP", start_bar: 1.0, length_bars: 7.0, color: "terracotta" }
      ]
    }
  ].freeze

  def index
  end

  def create_track
    project = ensure_workstation_project!
    track_params = params.expect(track: [ :kind, :name ])
    kind = track_params[:kind].to_s.downcase
    kind = "audio" unless [ "audio", "midi", "bus" ].include?(kind)

    next_pos = (project.tracks.maximum(:position) || -1) + 1
    next_index = (params[:current_count].presence || (project.tracks.count + 1)).to_i
    formatted_num = format("%02d", next_index)

    default_names = {
      "audio" => "Audio Stem #{next_index}",
      "midi" => "Synth Lead #{next_index}",
      "bus" => "Aux Group #{next_index}"
    }
    color_map = { "audio" => "#14b8a6", "midi" => "#f59e0b", "bus" => "#ea580c" }
    wave_map = { "audio" => "sub808", "midi" => "midiArp", "bus" => "drumBus" }

    track_name = track_params[:name].presence || "#{formatted_num}. #{default_names[kind]}"
    nr_enabled = kind == "audio"

    db_track = project.tracks.create!(
      name: track_name,
      track_type: kind,
      position: next_pos,
      color_hex: color_map[kind] || "#f59e0b",
      volume_db: 0.0,
      pan: 0.0,
      muted: false,
      soloed: false,
      armed: false,
      input_routing_jsonb: {
        "number" => formatted_num,
        "short_name" => track_name,
        "mixer_name" => track_name,
        "nr" => nr_enabled,
        "fx_active" => 1,
        "fx_total" => 4,
        "wave_style" => wave_map[kind],
        "clips" => []
      }
    )

    @new_track = build_workstation_track_hash(db_track, next_index, selected: false)
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
    Track.find_by(id: track_id)&.destroy

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
    track = Track.find_by(id: mixer_params[:track_id])

    if track
      updates = {}
      updates[:volume_db] = mixer_params[:gain_db].to_f if mixer_params.key?(:gain_db)
      if mixer_params.key?(:pan)
        pan_val = mixer_params[:pan].to_f
        updates[:pan] = (pan_val.abs > 1.0 ? pan_val / 50.0 : pan_val).clamp(-1.0, 1.0)
      end
      updates[:muted] = ActiveModel::Type::Boolean.new.cast(mixer_params[:muted]) if mixer_params.key?(:muted)
      updates[:soloed] = ActiveModel::Type::Boolean.new.cast(mixer_params[:soloed]) if mixer_params.key?(:soloed)
      updates[:armed] = ActiveModel::Type::Boolean.new.cast(mixer_params[:armed]) if mixer_params.key?(:armed)

      if mixer_params.key?(:nr)
        routing = (track.input_routing_jsonb || {}).dup
        routing["nr"] = ActiveModel::Type::Boolean.new.cast(mixer_params[:nr])
        updates[:input_routing_jsonb] = routing
      end

      track.update(updates) if updates.any?
    end

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

      project = ensure_workstation_project!
      @tracks = project.tracks.order(:position, :id).each_with_index.map do |db_track, idx|
        build_workstation_track_hash(db_track, idx + 1, selected: idx.zero?)
      end

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

    def ensure_workstation_project!
      project = Project.find_by(name: WORKSTATION_PROJECT_NAME)

      ActiveRecord::Base.transaction do
        if project.nil?
          owner = User.find_by(email: "saanskarastudios@gmail.com") || User.first
          branch = CrdtBranch.find_by(name: "main") || CrdtBranch.first

          project = Project.create!(
            name: WORKSTATION_PROJECT_NAME,
            user: owner,
            crdt_branch: branch,
            bpm: 128.0,
            time_signature_numerator: 4,
            time_signature_denominator: 4,
            ppqn: 960,
            sample_rate: 48000,
            root_note: 60,
            scale_name: "chromatic",
            master_volume_db: 0.0,
            swing_amount: 0.0,
            workspace_mode: "daw",
            theme_name: "midnight"
          )
        end

        if project.tracks.empty? && !project.settings_jsonb&.dig("seeded_defaults")
          DEFAULT_WORKSTATION_TRACKS.each_with_index do |attrs, idx|
            formatted_num = format("%02d", idx + 1)
            project.tracks.create!(
              name: attrs[:name],
              track_type: attrs[:track_type],
              position: attrs[:position],
              color_hex: attrs[:color_hex],
              volume_db: attrs[:volume_db],
              pan: attrs[:pan],
              muted: attrs[:muted],
              soloed: attrs[:soloed],
              armed: attrs[:armed],
              input_routing_jsonb: {
                "number" => formatted_num,
                "short_name" => attrs[:short_name],
                "mixer_name" => attrs[:mixer_name],
                "nr" => attrs[:nr],
                "fx_active" => attrs[:fx_active],
                "fx_total" => attrs[:fx_total],
                "wave_style" => attrs[:wave_style],
                "clips" => attrs[:clips].map(&:stringify_keys)
              }
            )
          end
          project.update!(settings_jsonb: (project.settings_jsonb || {}).merge("seeded_defaults" => true))
        end
      end

      project
    end

    def build_workstation_track_hash(db_track, display_index, selected: false)
      routing = db_track.input_routing_jsonb || {}
      kind = [ "audio", "midi", "bus" ].include?(db_track.track_type) ? db_track.track_type : "audio"
      badge_map = { "audio" => "AUDIO", "midi" => "MIDI", "bus" => "BUS" }
      formatted_num = routing["number"].presence || format("%02d", display_index)
      nr_enabled = routing.key?("nr") ? ActiveModel::Type::Boolean.new.cast(routing["nr"]) : (kind == "audio")
      pan_int = (db_track.pan.to_f * 50.0).round

      raw_clips = routing["clips"] || []
      clips = raw_clips.map do |clip|
        {
          title: clip["title"] || clip[:title],
          start_bar: (clip["start_bar"] || clip[:start_bar] || 1.0).to_f,
          length_bars: (clip["length_bars"] || clip[:length_bars] || 2.0).to_f,
          color: clip["color"] || clip[:color] || "cyan"
        }
      end

      {
        id: db_track.id,
        number: formatted_num,
        name: db_track.name,
        short_name: routing["short_name"].presence || db_track.name,
        mixer_name: routing["mixer_name"].presence || db_track.name,
        kind: kind,
        badge: badge_map[kind],
        gain_db: db_track.volume_db.to_f.round(1),
        pan: pan_int,
        muted: db_track.muted,
        soloed: db_track.soloed,
        armed: db_track.armed,
        nr: nr_enabled,
        selected: selected,
        fx_active: (routing["fx_active"] || 1).to_i,
        fx_total: (routing["fx_total"] || 4).to_i,
        mode_badge: nr_enabled ? "NR ON" : "DIRECT",
        wave_style: routing["wave_style"].presence || (kind == "midi" ? "midiArp" : (kind == "bus" ? "drumBus" : "sub808")),
        clips: clips
      }
    end
end
