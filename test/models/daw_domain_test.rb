# frozen_string_literal: true

require "test_helper"

class DawDomainTest < ActiveSupport::TestCase
  self.fixture_table_names = []

  test "Project defaults, enums, validations, and musical time conversion helpers" do
    branch = CrdtBranch.create!(name: "main-session", delta_vector: "AQT/AQ==")
    project = Project.create!(
      name: "Raga Bhairav 6-Deck Live Set",
      crdt_branch: branch
    )

    assert_equal 120.0, project.bpm.to_f
    assert_equal 4, project.time_signature_numerator
    assert_equal 4, project.time_signature_denominator
    assert_equal 960, project.ppqn
    assert_equal 48000, project.sample_rate
    assert_equal 60, project.root_note
    assert_equal "chromatic", project.scale_name
    assert_equal 0.0, project.master_volume_db
    assert_equal 0.0, project.swing_amount
    assert_equal "daw", project.workspace_mode
    assert project.daw?
    assert_equal "midnight", project.theme_name
    assert_equal({}, project.settings_jsonb)
    assert_not_nil project.uuid
    assert_not_nil project.slug
    assert_equal branch, project.crdt_branch

    # Musical tick <-> seconds <-> sample frame conversions at 120 BPM, 960 PPQN, 48kHz
    # 1 beat = 960 ticks = 0.5s = 24,000 frames; 1 bar (4 beats) = 3840 ticks = 2.0s = 96,000 frames
    assert_in_delta 0.5, project.ticks_to_seconds(960), 1e-6
    assert_in_delta 2.0, project.ticks_to_seconds(3840), 1e-6
    assert_equal 960, project.seconds_to_ticks(0.5)
    assert_equal 3840, project.seconds_to_ticks(2.0)
    assert_equal 24000, project.ticks_to_frames(960)
    assert_equal 96000, project.ticks_to_frames(3840)

    # Validation checks
    invalid_project = Project.new(name: "Bad Tempo", bpm: 0, ppqn: -960)
    assert_not invalid_project.valid?
    assert invalid_project.errors[:bpm].any?
    assert invalid_project.errors[:ppqn].any?
  end

  test "Track types, DJ deck validation (1..6), and self-referential parent bus routing" do
    project = Project.create!(name: "Bus Routing Session", workspace_mode: :dj_6deck)
    assert project.dj_6deck?

    drum_bus = project.tracks.create!(
      name: "Drum Bus",
      track_type: :bus,
      position: 0
    )
    kick_track = project.tracks.create!(
      name: "808 Kick",
      track_type: :audio,
      parent_bus_track: drum_bus,
      position: 1,
      fx_chain_jsonb: [ { plugin: "saanskara_saturator", drive_db: 4.5 } ]
    )
    dj_deck = project.tracks.create!(
      name: "Deck A",
      track_type: :dj_deck,
      deck_number: 1,
      position: 2
    )

    assert drum_bus.bus?
    assert kick_track.audio?
    assert dj_deck.dj_deck?
    assert_equal drum_bus, kick_track.parent_bus_track
    assert_includes drum_bus.child_tracks, kick_track
    assert_equal 1, kick_track.fx_chain_jsonb.size

    invalid_deck = project.tracks.build(name: "Deck 7", track_type: :dj_deck, deck_number: 7)
    assert_not invalid_deck.valid?
    assert invalid_deck.errors[:deck_number].any?
  end

  test "AudioSample and MidiClip binary/JSONB payloads and non-destructive TrackClip reuse" do
    project = Project.create!(name: "Non-Destructive Arrangement")
    audio_track = project.tracks.create!(name: "Tabla Stem", track_type: :audio, position: 0)
    midi_track = project.tracks.create!(name: "Sitar Lead", track_type: :midi, position: 1)

    peaks_blob = [ -0.85, 0.92, -0.40, 0.45 ].pack("e*")
    sample = AudioSample.create!(
      project: project,
      name: "Tabla_Kayda_120bpm.wav",
      storage_key: "samples/tabla_kayda_120.wav",
      checksum_sha256: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      sample_rate: 48000,
      channels: 2,
      bit_depth: 24,
      total_frames: 96000,
      duration_ms: 2000,
      detected_bpm: 120.0,
      detected_key: "8A",
      is_loop: true,
      waveform_peaks_binary: peaks_blob,
      beatgrid_jsonb: [ { tick: 0, bar: 1 }, { tick: 960, bar: 1 } ],
      cue_points_jsonb: [ { slot: 1, frame: 0, label: "Sam (Downbeat)", color: "#ef4444" } ]
    )
    assert_equal peaks_blob, sample.reload.waveform_peaks_binary

    midi_events = [ { "t" => 0, "d" => 480, "n" => 60, "v" => 110, "ch" => 0 } ]
    midi_blob = [ 0, 480, 60, 110, 0, 0 ].pack("V2C4")
    midi_clip = project.midi_clips.create!(
      name: "Alap Phrase 1",
      length_ticks: 3840,
      note_count: 1,
      events_jsonb: midi_events,
      events_binary: midi_blob
    )
    assert_equal midi_events, midi_clip.reload.events_jsonb
    assert_equal midi_blob, midi_clip.events_binary

    # Place two non-destructive TrackClips referencing the same AudioSample
    clip_bar_1 = project.track_clips.create!(
      track: audio_track,
      clip_kind: :audio,
      audio_sample: sample,
      name: "Tabla Intro",
      start_tick: 0,
      duration_ticks: 3840,
      gain_db: 0.0
    )
    clip_bar_2 = project.track_clips.create!(
      track: audio_track,
      clip_kind: :audio,
      audio_sample: sample,
      name: "Tabla Chopped +3dB",
      start_tick: 3840,
      duration_ticks: 1920,
      source_offset_ticks: 960,
      gain_db: 3.0,
      transpose_semitones: 2,
      detune_cents: -15.5,
      time_stretch_ratio: 0.5,
      fade_in_ticks: 120,
      fade_out_ticks: 240
    )
    midi_placement = project.track_clips.create!(
      track: midi_track,
      clip_kind: :midi,
      midi_clip: midi_clip,
      name: "Alap Lead Bar 3",
      start_tick: 7680,
      duration_ticks: 3840
    )

    assert_equal 2, sample.track_clips.count
    assert clip_bar_1.audio?
    assert midi_placement.midi?

    # Viewport windowing scope: in_tick_range(start_tick, end_tick)
    bar_1_clips = audio_track.track_clips.in_tick_range(0, 3840)
    assert_includes bar_1_clips, clip_bar_1
    assert_not_includes bar_1_clips, clip_bar_2

    bar_2_clips = audio_track.track_clips.in_tick_range(3840, 7680)
    assert_not_includes bar_2_clips, clip_bar_1
    assert_includes bar_2_clips, clip_bar_2

    full_window = project.track_clips.in_tick_range(0, 11520)
    assert_equal 3, full_window.count
  end

  test "TrackClip validates source asset matches clip_kind and duration_ticks > 0" do
    project = Project.create!(name: "Clip Validation Project")
    track = project.tracks.create!(name: "Hybrid Track", track_type: :audio)
    sample = AudioSample.create!(project: project, name: "Hit.wav")
    midi_clip = project.midi_clips.create!(name: "Chord.mid")

    # Audio clip missing audio_sample
    missing_audio = project.track_clips.build(track: track, clip_kind: :audio, duration_ticks: 960)
    assert_not missing_audio.valid?
    assert missing_audio.errors[:audio_sample].any?

    # Audio clip with midi_clip attached instead
    mismatched_audio = project.track_clips.build(
      track: track,
      clip_kind: :audio,
      audio_sample: sample,
      midi_clip: midi_clip,
      duration_ticks: 960
    )
    assert_not mismatched_audio.valid?
    assert mismatched_audio.errors[:midi_clip].any?

    # MIDI clip missing midi_clip
    missing_midi = project.track_clips.build(track: track, clip_kind: :midi, duration_ticks: 960)
    assert_not missing_midi.valid?
    assert missing_midi.errors[:midi_clip].any?

    # Invalid duration_ticks <= 0
    zero_duration = project.track_clips.build(
      track: track,
      clip_kind: :audio,
      audio_sample: sample,
      duration_ticks: 0
    )
    assert_not zero_duration.valid?
    assert zero_duration.errors[:duration_ticks].any?
  end

  test "AutomationLane supports both track-level and clip-level parameter envelopes" do
    project = Project.create!(name: "Automation Project")
    track = project.tracks.create!(name: "Synth", track_type: :instrument)
    midi_clip = project.midi_clips.create!(name: "Arp")
    track_clip = project.track_clips.create!(
      track: track,
      clip_kind: :midi,
      midi_clip: midi_clip,
      start_tick: 0,
      duration_ticks: 3840
    )

    points_binary = [ 0.0, 0.0, 0.0, 1920.0, 0.8, 0.25, 3840.0, 1.0, 0.0 ].pack("e*")
    track_lane = project.automation_lanes.create!(
      track: track,
      parameter_path: "fx.0.cutoff_hz",
      min_value: 20.0,
      max_value: 20000.0,
      points_jsonb: [
        { "tick" => 0, "value" => 200.0, "curve" => 0.0 },
        { "tick" => 3840, "value" => 12000.0, "curve" => 0.35 }
      ],
      points_binary: points_binary
    )

    clip_lane = project.automation_lanes.create!(
      track: track,
      track_clip: track_clip,
      parameter_path: "clip.gain_db",
      min_value: -24.0,
      max_value: 6.0,
      points_jsonb: [ { "tick" => 0, "value" => 0.0, "curve" => 0.0 } ]
    )

    assert_includes track.automation_lanes, track_lane
    assert_includes track_clip.automation_lanes, clip_lane
    assert_equal points_binary, track_lane.reload.points_binary
  end

  test "SaanskaraDsp compiles with C23 standard and executes apply_golden_ratio" do
    assert_equal 202311, SaanskaraDsp.c_standard_version
    result = SaanskaraDsp.apply_golden_ratio(0.5, 1)
    assert_in_delta 0.8090169943749475, result, 1e-9
    result_10 = SaanskaraDsp.apply_golden_ratio(0.5, 10)
    assert_in_delta 0.8090169943749475, result_10, 1e-9
  end
end
