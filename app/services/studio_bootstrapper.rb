# frozen_string_literal: true

class StudioBootstrapper
  DEFAULT_PROJECT_NAME = "Saanskara Raga Session 01"

  DEFAULT_TRACKS = [
    {
      name: "01 • Sitar Lead",
      track_type: "audio",
      deck_number: 1,
      position: 0,
      armed: true,
      muted: false,
      soloed: false,
      color_hex: "#f59e0b",
      volume_db: -1.5,
      pan: -0.15,
      fx_chain_jsonb: [
        { "plugin" => "saanskara_spanda_eq", "low_cut_hz" => 85, "presence_db" => 2.4, "active" => true },
        { "plugin" => "saanskara_comb_reverb", "room_size" => 0.68, "wet" => 0.28, "active" => true }
      ]
    },
    {
      name: "02 • Tabla Teental Groove",
      track_type: "midi",
      deck_number: 2,
      position: 1,
      armed: false,
      muted: false,
      soloed: false,
      color_hex: "#10b981",
      volume_db: 0.0,
      pan: 0.1,
      fx_chain_jsonb: [
        { "plugin" => "saanskara_transient_shaper", "attack_db" => 3.5, "sustain_db" => -1.0, "active" => true }
      ]
    },
    {
      name: "03 • Tanpura Sub Drone",
      track_type: "instrument",
      deck_number: 3,
      position: 2,
      armed: false,
      muted: false,
      soloed: false,
      color_hex: "#38bdf8",
      volume_db: -3.0,
      pan: 0.0,
      fx_chain_jsonb: [
        { "plugin" => "saanskara_sub_harmonic", "drive_db" => 2.0, "cutoff_hz" => 140, "active" => true }
      ]
    },
    {
      name: "04 • Analog Perc Stem",
      track_type: "stem",
      deck_number: 4,
      position: 3,
      armed: false,
      muted: false,
      soloed: false,
      color_hex: "#a855f7",
      volume_db: -2.0,
      pan: -0.25,
      fx_chain_jsonb: [
        { "plugin" => "saanskara_tape_saturator", "drive_db" => 4.2, "warmth" => 0.65, "active" => true }
      ]
    },
    {
      name: "05 • Vocal Alaap Chop",
      track_type: "dj_deck",
      deck_number: 5,
      position: 4,
      armed: false,
      muted: false,
      soloed: false,
      color_hex: "#ec4899",
      volume_db: -1.0,
      pan: 0.2,
      fx_chain_jsonb: [
        { "plugin" => "saanskara_formant_filter", "shift_semitones" => 3, "mix" => 0.4, "active" => true }
      ]
    },
    {
      name: "06 • Atmos Riser Deck",
      track_type: "dj_deck",
      deck_number: 6,
      position: 5,
      armed: false,
      muted: false,
      soloed: false,
      color_hex: "#eab308",
      volume_db: -4.0,
      pan: 0.0,
      fx_chain_jsonb: [
        { "plugin" => "saanskara_shimmer_delay", "feedback" => 0.55, "wet" => 0.45, "active" => true }
      ]
    }
  ].freeze

  class << self
    def ensure_default_project!
      project = Project.find_by(name: DEFAULT_PROJECT_NAME) || Project.order(:id).first

      ActiveRecord::Base.transaction do
        branches = CrdtBranch.default_branches
        primary_branch = branches.first || CrdtBranch.order(:id).first
        ProjectCollaborator.default_roster_for("proj_default")
        StudioChatMessage.default_messages_for("project_room")

        if project.nil?
          owner = User.find_by(email: "saanskarastudios@gmail.com") || User.first

          project = Project.create!(
            name: DEFAULT_PROJECT_NAME,
            user: owner,
            crdt_branch: primary_branch,
            bpm: 124.0,
            time_signature_numerator: 4,
            time_signature_denominator: 4,
            ppqn: 960,
            sample_rate: 48000,
            root_note: 60,
            scale_name: "bhairavi",
            master_volume_db: 0.0,
            swing_amount: 0.08,
            workspace_mode: "daw",
            theme_name: "midnight",
            settings_jsonb: {
              "snap_ticks" => 960,
              "loop_bars" => 8,
              "crossfader" => 0.0,
              "quantize" => "1/16"
            }
          )
        elsif project.crdt_branch_id.nil? && primary_branch.present?
          project.update_column(:crdt_branch_id, primary_branch.id)
          project.crdt_branch = primary_branch
        end

        ProjectCollaborator.default_roster_for(project.slug) if project.slug.present?
        seed_tracks_and_clips!(project) if project.tracks.empty?
      end

      load_full_project(project.id)
    end

    def load_full_project(project_id)
      Project.includes(
        :crdt_branch,
        :automation_lanes,
        tracks: [
          :automation_lanes,
          { track_clips: [ :audio_sample, :midi_clip ] }
        ]
      ).find(project_id)
    end

    def serialize_project(project)
      tracks_payload = project.tracks.sort_by { |t| [ t.position, t.id ] }.map do |track|
        serialize_track(track)
      end

      branches = CrdtBranch.default_branches
      active_branch = project.crdt_branch || branches.first
      slug_scope = [ project.slug, "proj_default" ].compact.uniq
      collaborators = ProjectCollaborator.where(project_slug: slug_scope).order(:id).to_a
      collaborators = ProjectCollaborator.default_roster_for("proj_default") if collaborators.empty?
      chat_messages = StudioChatMessage.where(room_type: "project_room").order(:id).last(30)
      chat_messages = StudioChatMessage.default_messages_for("project_room") if chat_messages.empty?

      {
        id: project.id,
        uuid: project.uuid,
        name: project.name,
        slug: project.slug,
        bpm: project.bpm.to_f.round(2),
        time_signature_numerator: project.time_signature_numerator,
        time_signature_denominator: project.time_signature_denominator,
        ppqn: project.ppqn,
        sample_rate: project.sample_rate,
        root_note: project.root_note,
        scale_name: project.scale_name,
        master_volume_db: project.master_volume_db.to_f.round(2),
        swing_amount: project.swing_amount.to_f.round(2),
        workspace_mode: project.workspace_mode,
        theme_name: project.theme_name,
        settings: project.settings_jsonb || {},
        state_jsonb: project.state_jsonb || {},
        crdt_branch: CrdtSyncEngine.serialize_branch(active_branch),
        branches: branches.map { |b| CrdtSyncEngine.serialize_branch(b) },
        collaborators: collaborators.map { |c| serialize_collaborator(c) },
        chat_messages: chat_messages.map { |m| serialize_chat_message(m) },
        tracks: tracks_payload,
        automation_lanes: project.automation_lanes.map { |lane| serialize_automation_lane(lane) }
      }
    end

    def serialize_collaborator(collab)
      {
        id: collab.id,
        project_slug: collab.project_slug,
        username: collab.username,
        external_user_id: collab.external_user_id,
        email: collab.email,
        role: collab.role,
        added_at_label: collab.added_at_label
      }
    end

    def serialize_chat_message(msg)
      {
        id: msg.id,
        sender_name: msg.sender_name,
        sender_role: msg.sender_role,
        body: msg.body,
        room_type: msg.room_type,
        recipient_handle: msg.recipient_handle,
        sent_at_label: msg.sent_at_label
      }
    end

    def serialize_track(track)
      clips = track.track_clips.sort_by { |c| [ c.start_tick, c.id ] }.map do |clip|
        serialize_track_clip(clip)
      end

      primary_sample = track.track_clips.detect(&:audio_sample)&.audio_sample
      cue_points = primary_sample&.cue_points_jsonb.presence || default_cue_points_for(track)
      detected_bpm = primary_sample&.detected_bpm&.to_f || track.project&.bpm&.to_f || 124.0
      detected_key = primary_sample&.detected_key.presence || "8A • C Bhairavi"
      peaks = extract_waveform_peaks(primary_sample)

      {
        id: track.id,
        uuid: track.uuid,
        project_id: track.project_id,
        name: track.name,
        track_type: track.track_type,
        deck_number: track.deck_number,
        position: track.position,
        color_hex: track.color_hex,
        volume_db: track.volume_db.to_f.round(2),
        pan: track.pan.to_f.round(2),
        muted: track.muted,
        soloed: track.soloed,
        armed: track.armed,
        fx_chain: track.fx_chain_jsonb || [],
        state_jsonb: track.state_jsonb || {},
        detected_bpm: detected_bpm.round(2),
        detected_key: detected_key,
        cue_points: cue_points,
        waveform_peaks: peaks,
        clips: clips
      }
    end

    def serialize_track_clip(clip)
      sample = clip.audio_sample
      midi = clip.midi_clip

      {
        id: clip.id,
        uuid: clip.uuid,
        project_id: clip.project_id,
        track_id: clip.track_id,
        clip_kind: clip.clip_kind,
        audio_sample_id: clip.audio_sample_id,
        midi_clip_id: clip.midi_clip_id,
        name: clip.name.presence || midi&.name || sample&.name || "Clip",
        color_hex: clip.color_hex.presence || clip.track&.color_hex || "#f59e0b",
        start_tick: clip.start_tick.to_i,
        duration_ticks: clip.duration_ticks.to_i,
        source_offset_ticks: clip.source_offset_ticks.to_i,
        loop_enabled: clip.loop_enabled,
        loop_start_tick: clip.loop_start_tick.to_i,
        loop_end_tick: clip.loop_end_tick.to_i,
        gain_db: clip.gain_db.to_f.round(2),
        transpose_semitones: clip.transpose_semitones.to_i,
        detune_cents: clip.detune_cents.to_f.round(1),
        time_stretch_ratio: clip.time_stretch_ratio.to_f.round(3),
        fade_in_ticks: clip.fade_in_ticks.to_i,
        fade_out_ticks: clip.fade_out_ticks.to_i,
        muted: clip.muted,
        state_jsonb: clip.state_jsonb || {},
        waveform_peaks: extract_waveform_peaks(sample),
        midi_events: midi&.events_jsonb || []
      }
    end

    def serialize_automation_lane(lane)
      {
        id: lane.id,
        uuid: lane.uuid,
        project_id: lane.project_id,
        track_id: lane.track_id,
        track_clip_id: lane.track_clip_id,
        parameter_path: lane.parameter_path,
        min_value: lane.min_value,
        max_value: lane.max_value,
        points: lane.points_jsonb || [],
        bypassed: lane.bypassed,
        state_jsonb: lane.state_jsonb || {}
      }
    end

    def ensure_default_clip_source_for!(track, clip_kind)
      project = track.project
      if clip_kind.to_s == "midi"
        midi = project.midi_clips.first || create_default_midi_clip!(project, track.name)
        [ nil, midi ]
      else
        sample = project.audio_samples.first || create_default_audio_sample!(project, track.name)
        [ sample, nil ]
      end
    end

    def create_default_midi_clip!(project, label = "Raga Phrase")
      notes = [
        { "t" => 0, "d" => 480, "n" => 60, "v" => 108, "ch" => 0 },
        { "t" => 480, "d" => 480, "n" => 61, "v" => 96, "ch" => 0 },
        { "t" => 960, "d" => 960, "n" => 63, "v" => 112, "ch" => 0 },
        { "t" => 1920, "d" => 480, "n" => 65, "v" => 104, "ch" => 0 },
        { "t" => 2400, "d" => 480, "n" => 67, "v" => 115, "ch" => 0 },
        { "t" => 2880, "d" => 960, "n" => 68, "v" => 100, "ch" => 0 }
      ]
      project.midi_clips.create!(
        name: "#{label} Pattern",
        length_ticks: 3840,
        note_count: notes.size,
        events_jsonb: notes,
        events_binary: notes.flat_map { |e| [ e["t"], e["d"], e["n"], e["v"], e["ch"], 0 ] }.pack("V2C4" * notes.size)
      )
    end

    def create_default_audio_sample!(project, label = "Studio Stem", seed_phase: 0.4)
      peaks = generate_synthetic_peaks(48, seed_phase)
      project.audio_samples.create!(
        name: "#{label}.wav",
        storage_key: "samples/#{label.parameterize}.wav",
        checksum_sha256: Digest::SHA256.hexdigest(label),
        sample_rate: project.sample_rate,
        channels: 2,
        bit_depth: 24,
        total_frames: 185_806,
        duration_ms: 3870,
        detected_bpm: project.bpm,
        detected_key: "8A • C Bhairavi",
        peak_db: -0.8,
        integrated_lufs: -11.4,
        is_loop: true,
        waveform_peaks_binary: peaks.pack("e*"),
        beatgrid_jsonb: (0..7).map { |beat| { "tick" => beat * 960, "bar" => (beat / 4) + 1, "beat" => (beat % 4) + 1 } },
        cue_points_jsonb: [
          { "slot" => 1, "tick" => 0, "label" => "CUE 1 • Sam", "color" => "#f59e0b" },
          { "slot" => 2, "tick" => 3840, "label" => "CUE 2 • Drop", "color" => "#10b981" },
          { "slot" => 3, "tick" => 7680, "label" => "CUE 3 • Alaap", "color" => "#38bdf8" },
          { "slot" => 4, "tick" => 11520, "label" => "CUE 4 • Outro", "color" => "#ec4899" }
        ],
        dsp_metadata_jsonb: { "peaks" => peaks }
      )
    end

    private

      def seed_tracks_and_clips!(project)
        created_tracks = DEFAULT_TRACKS.map do |attrs|
          project.tracks.create!(attrs)
        end

        # Audio Samples for Tracks 1, 4, 5, 6
        sitar_sample = create_default_audio_sample!(project, "Sitar_Bhairavi_Alap_124bpm", seed_phase: 0.25)
        perc_sample = create_default_audio_sample!(project, "Analog_Dholak_Stem_124bpm", seed_phase: 1.15)
        vocal_sample = create_default_audio_sample!(project, "Vocal_Sargam_Chop_124bpm", seed_phase: 2.05)
        riser_sample = create_default_audio_sample!(project, "Atmos_Cymbal_Swell_124bpm", seed_phase: 3.10)

        # MIDI Clips for Tracks 2 (Tabla Teental Groove) & 3 (Tanpura Sub Drone)
        tabla_events = [
          { "t" => 0, "d" => 240, "n" => 60, "v" => 120, "ch" => 9 },    # Dha (Sam)
          { "t" => 480, "d" => 240, "n" => 63, "v" => 98, "ch" => 9 },   # Dhin
          { "t" => 960, "d" => 240, "n" => 63, "v" => 104, "ch" => 9 },  # Dhin
          { "t" => 1440, "d" => 240, "n" => 60, "v" => 112, "ch" => 9 }, # Dha
          { "t" => 1920, "d" => 240, "n" => 67, "v" => 116, "ch" => 9 }, # Dha
          { "t" => 2400, "d" => 240, "n" => 65, "v" => 92, "ch" => 9 },  # Tin
          { "t" => 2880, "d" => 240, "n" => 68, "v" => 100, "ch" => 9 }, # Tin
          { "t" => 3360, "d" => 240, "n" => 72, "v" => 118, "ch" => 9 }  # Ta
        ]
        tabla_midi = project.midi_clips.create!(
          name: "Teental 16-Matra Kayda",
          length_ticks: 3840,
          note_count: tabla_events.size,
          events_jsonb: tabla_events,
          events_binary: tabla_events.flat_map { |e| [ e["t"], e["d"], e["n"], e["v"], e["ch"], 0 ] }.pack("V2C4" * tabla_events.size)
        )

        tanpura_events = [
          { "t" => 0, "d" => 1920, "n" => 48, "v" => 110, "ch" => 1 },    # Pa / Sa的低音
          { "t" => 960, "d" => 1920, "n" => 55, "v" => 96, "ch" => 1 },   # Fifth (Pa)
          { "t" => 1920, "d" => 1920, "n" => 60, "v" => 105, "ch" => 1 }, # Root (Sa)
          { "t" => 2880, "d" => 960, "n" => 56, "v" => 90, "ch" => 1 }    # Komal Dha
        ]
        tanpura_midi = project.midi_clips.create!(
          name: "Tanpura Sa-Pa Drone",
          length_ticks: 3840,
          note_count: tanpura_events.size,
          events_jsonb: tanpura_events,
          events_binary: tanpura_events.flat_map { |e| [ e["t"], e["d"], e["n"], e["v"], e["ch"], 0 ] }.pack("V2C4" * tanpura_events.size)
        )

        t1, t2, t3, t4, t5, t6 = created_tracks

        # Track 1: Sitar Lead clips across Bars 1..3 and 5..7
        project.track_clips.create!(
          track: t1,
          clip_kind: "audio",
          audio_sample: sitar_sample,
          name: "Sitar Alaap Intro",
          color_hex: t1.color_hex,
          start_tick: 0,
          duration_ticks: 7680,
          loop_enabled: true,
          loop_end_tick: 7680,
          gain_db: 0.0
        )
        project.track_clips.create!(
          track: t1,
          clip_kind: "audio",
          audio_sample: sitar_sample,
          name: "Sitar Jhala Peak",
          color_hex: t1.color_hex,
          start_tick: 15360,
          duration_ticks: 7680,
          source_offset_ticks: 960,
          gain_db: 1.5
        )

        # Track 2: Tabla Teental Groove MIDI clips across Bars 1..8
        [ 0, 7680, 15360, 23040 ].each_with_index do |tick, idx|
          project.track_clips.create!(
            track: t2,
            clip_kind: "midi",
            midi_clip: tabla_midi,
            name: "Tabla Teental #{idx + 1}",
            color_hex: t2.color_hex,
            start_tick: tick,
            duration_ticks: 7680,
            loop_enabled: true,
            loop_end_tick: 3840
          )
        end

        # Track 3: Tanpura Sub Drone MIDI clips across Bars 1..4 and 5..8
        [ 0, 15360 ].each_with_index do |tick, idx|
          project.track_clips.create!(
            track: t3,
            clip_kind: "midi",
            midi_clip: tanpura_midi,
            name: "Tanpura Sub #{idx + 1}",
            color_hex: t3.color_hex,
            start_tick: tick,
            duration_ticks: 11520,
            loop_enabled: true,
            loop_end_tick: 3840
          )
        end

        # Track 4: Analog Perc Stem across Bars 2..6
        project.track_clips.create!(
          track: t4,
          clip_kind: "audio",
          audio_sample: perc_sample,
          name: "Dholak Transient Break",
          color_hex: t4.color_hex,
          start_tick: 3840,
          duration_ticks: 15360,
          loop_enabled: true,
          loop_end_tick: 7680
        )

        # Track 5: Vocal Alaap Chop across Bars 3..5 and 7..8
        project.track_clips.create!(
          track: t5,
          clip_kind: "audio",
          audio_sample: vocal_sample,
          name: "Sargam Vox Hook A",
          color_hex: t5.color_hex,
          start_tick: 7680,
          duration_ticks: 7680
        )
        project.track_clips.create!(
          track: t5,
          clip_kind: "audio",
          audio_sample: vocal_sample,
          name: "Sargam Vox Hook B",
          color_hex: t5.color_hex,
          start_tick: 23040,
          duration_ticks: 7680,
          transpose_semitones: 3
        )

        # Track 6: Atmos Riser Deck across Bars 4..5 and 7..8
        project.track_clips.create!(
          track: t6,
          clip_kind: "audio",
          audio_sample: riser_sample,
          name: "Atmos Riser Swell",
          color_hex: t6.color_hex,
          start_tick: 11520,
          duration_ticks: 3840,
          fade_in_ticks: 1920
        )
        project.track_clips.create!(
          track: t6,
          clip_kind: "audio",
          audio_sample: riser_sample,
          name: "Final Drop Riser",
          color_hex: t6.color_hex,
          start_tick: 26880,
          duration_ticks: 3840,
          fade_in_ticks: 1920
        )

        # Automation Lanes
        project.automation_lanes.create!(
          track: t1,
          parameter_path: "mixer.volume_db",
          min_value: -24.0,
          max_value: 6.0,
          points_jsonb: [
            { "tick" => 0, "value" => -3.0, "curve" => 0.0 },
            { "tick" => 7680, "value" => 0.0, "curve" => 0.25 },
            { "tick" => 15360, "value" => -1.5, "curve" => -0.15 },
            { "tick" => 26880, "value" => 1.2, "curve" => 0.0 }
          ],
          points_binary: [ 0.0, -3.0, 0.0, 7680.0, 0.0, 0.25, 15360.0, -1.5, -0.15, 26880.0, 1.2, 0.0 ].pack("e*")
        )

        project.automation_lanes.create!(
          track: t5,
          parameter_path: "dj.deck_5.filter_cutoff",
          min_value: 20.0,
          max_value: 20000.0,
          points_jsonb: [
            { "tick" => 7680, "value" => 420.0, "curve" => 0.4 },
            { "tick" => 15360, "value" => 16500.0, "curve" => 0.0 }
          ]
        )
      end

      def generate_synthetic_peaks(count, phase)
        Array.new(count) do |i|
          ratio = i.to_f / count
          env = Math.sin(ratio * Math::PI)
          val = (Math.sin(i * 0.65 + phase) * 0.55 + Math.cos(i * 1.35 - phase) * 0.35) * (0.35 + env * 0.65)
          val.clamp(-1.0, 1.0).round(3)
        end
      end

      def extract_waveform_peaks(sample)
        return generate_synthetic_peaks(32, 0.5) if sample.nil?

        if sample.dsp_metadata_jsonb.is_a?(Hash) && sample.dsp_metadata_jsonb["peaks"].is_a?(Array)
          return sample.dsp_metadata_jsonb["peaks"]
        end

        if sample.waveform_peaks_binary.present?
          unpacked = sample.waveform_peaks_binary.unpack("e*")
          return unpacked.map { |v| v.round(3) } if unpacked.any?
        end

        generate_synthetic_peaks(32, sample.id.to_f)
      end

      def default_cue_points_for(track)
        [
          { "slot" => 1, "tick" => 0, "label" => "CUE 1 • Sam", "color" => track.color_hex },
          { "slot" => 2, "tick" => 3840, "label" => "CUE 2 • Groove", "color" => "#10b981" },
          { "slot" => 3, "tick" => 7680, "label" => "CUE 3 • Break", "color" => "#38bdf8" },
          { "slot" => 4, "tick" => 15360, "label" => "CUE 4 • Drop", "color" => "#ec4899" }
        ]
      end
  end
end
