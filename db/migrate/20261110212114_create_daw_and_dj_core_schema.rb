# frozen_string_literal: true

class CreateDawAndDjCoreSchema < ActiveRecord::Migration[8.1]
  def change
    create_table :projects do |t|
      t.uuid :uuid, null: false, default: -> { "gen_random_uuid()" }
      t.references :user, null: true, foreign_key: { on_delete: :nullify }
      t.references :crdt_branch, null: true, foreign_key: { on_delete: :nullify }
      t.string :name, null: false
      t.string :slug
      t.decimal :bpm, precision: 6, scale: 3, default: "120.0", null: false
      t.integer :time_signature_numerator, default: 4, null: false
      t.integer :time_signature_denominator, default: 4, null: false
      t.integer :ppqn, default: 960, null: false
      t.integer :sample_rate, default: 48000, null: false
      t.integer :root_note, default: 60
      t.string :scale_name, default: "chromatic"
      t.float :master_volume_db, default: 0.0, null: false
      t.float :swing_amount, default: 0.0, null: false
      t.string :workspace_mode, default: "daw", null: false
      t.string :theme_name, default: "midnight", null: false
      t.jsonb :settings_jsonb, default: {}, null: false
      t.jsonb :state_jsonb, default: {}, null: false
      t.integer :lock_version, default: 0, null: false

      t.timestamps

      t.index :uuid, unique: true
      t.index :slug
      t.check_constraint "bpm > 0", name: "check_projects_bpm_positive"
      t.check_constraint "ppqn > 0", name: "check_projects_ppqn_positive"
      t.check_constraint "sample_rate > 0", name: "check_projects_sample_rate_positive"
    end

    create_table :tracks do |t|
      t.uuid :uuid, null: false, default: -> { "gen_random_uuid()" }
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.references :parent_bus_track, null: true, foreign_key: { to_table: :tracks, on_delete: :nullify }
      t.string :name, null: false
      t.string :track_type, default: "audio", null: false
      t.integer :deck_number
      t.integer :position, default: 0, null: false
      t.string :color_hex, default: "#f59e0b", null: false
      t.float :volume_db, default: 0.0, null: false
      t.float :pan, default: 0.0, null: false
      t.boolean :muted, default: false, null: false
      t.boolean :soloed, default: false, null: false
      t.boolean :armed, default: false, null: false
      t.jsonb :input_routing_jsonb, default: {}, null: false
      t.jsonb :fx_chain_jsonb, default: [], null: false
      t.jsonb :state_jsonb, default: {}, null: false
      t.integer :lock_version, default: 0, null: false

      t.timestamps

      t.index :uuid, unique: true
      t.index [ :project_id, :position ]
      t.index [ :project_id, :deck_number ]
      t.check_constraint "deck_number IS NULL OR (deck_number >= 1 AND deck_number <= 6)", name: "check_tracks_deck_number_range"
      t.check_constraint "pan >= -1.0 AND pan <= 1.0", name: "check_tracks_pan_range"
    end

    create_table :audio_samples do |t|
      t.uuid :uuid, null: false, default: -> { "gen_random_uuid()" }
      t.references :project, null: true, foreign_key: { on_delete: :nullify }
      t.string :name, null: false
      t.string :storage_key
      t.string :checksum_sha256
      t.integer :sample_rate, default: 48000, null: false
      t.integer :channels, default: 2, null: false
      t.integer :bit_depth, default: 24, null: false
      t.bigint :total_frames, default: 0, null: false
      t.bigint :trim_start_frame, default: 0, null: false
      t.bigint :trim_end_frame
      t.integer :duration_ms, default: 0, null: false
      t.decimal :detected_bpm, precision: 6, scale: 3
      t.string :detected_key
      t.float :peak_db, default: 0.0
      t.float :integrated_lufs
      t.boolean :is_loop, default: false, null: false
      t.binary :waveform_peaks_binary
      t.jsonb :beatgrid_jsonb, default: [], null: false
      t.jsonb :cue_points_jsonb, default: [], null: false
      t.jsonb :dsp_metadata_jsonb, default: {}, null: false
      t.jsonb :state_jsonb, default: {}, null: false
      t.integer :lock_version, default: 0, null: false

      t.timestamps

      t.index :uuid, unique: true
      t.index :storage_key
      t.index :checksum_sha256
      t.check_constraint "sample_rate > 0", name: "check_audio_samples_sample_rate_positive"
      t.check_constraint "channels > 0", name: "check_audio_samples_channels_positive"
      t.check_constraint "total_frames >= 0", name: "check_audio_samples_total_frames_non_negative"
    end

    create_table :midi_clips do |t|
      t.uuid :uuid, null: false, default: -> { "gen_random_uuid()" }
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.bigint :length_ticks, default: 3840, null: false
      t.integer :note_count, default: 0, null: false
      t.jsonb :events_jsonb, default: [], null: false
      t.binary :events_binary
      t.jsonb :groove_template_jsonb, default: {}, null: false
      t.jsonb :state_jsonb, default: {}, null: false
      t.integer :lock_version, default: 0, null: false

      t.timestamps

      t.index :uuid, unique: true
      t.check_constraint "length_ticks > 0", name: "check_midi_clips_length_ticks_positive"
      t.check_constraint "note_count >= 0", name: "check_midi_clips_note_count_non_negative"
    end

    create_table :track_clips do |t|
      t.uuid :uuid, null: false, default: -> { "gen_random_uuid()" }
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.references :track, null: false, foreign_key: { on_delete: :cascade }
      t.string :clip_kind, null: false
      t.references :audio_sample, null: true, foreign_key: { on_delete: :restrict }
      t.references :midi_clip, null: true, foreign_key: { on_delete: :cascade }
      t.string :name
      t.string :color_hex
      t.integer :scene_slot_index
      t.bigint :start_tick, default: 0, null: false
      t.bigint :duration_ticks, default: 3840, null: false
      t.bigint :source_offset_ticks, default: 0, null: false
      t.bigint :source_start_frame, default: 0, null: false
      t.bigint :source_end_frame
      t.boolean :loop_enabled, default: false, null: false
      t.bigint :loop_start_tick, default: 0, null: false
      t.bigint :loop_end_tick, default: 3840, null: false
      t.float :gain_db, default: 0.0, null: false
      t.integer :transpose_semitones, default: 0, null: false
      t.float :detune_cents, default: 0.0, null: false
      t.boolean :warp_enabled, default: true, null: false
      t.string :warp_algorithm, default: "complex"
      t.float :time_stretch_ratio, default: 1.0, null: false
      t.bigint :fade_in_ticks, default: 0, null: false
      t.bigint :fade_out_ticks, default: 0, null: false
      t.float :fade_curve, default: 0.0, null: false
      t.boolean :muted, default: false, null: false
      t.jsonb :warp_markers_jsonb, default: [], null: false
      t.jsonb :state_jsonb, default: {}, null: false
      t.integer :lock_version, default: 0, null: false

      t.timestamps

      t.index :uuid, unique: true
      t.index [ :track_id, :start_tick, :duration_ticks ]
      t.index [ :project_id, :start_tick ]
      t.check_constraint "duration_ticks > 0", name: "check_track_clips_duration_ticks_positive"
      t.check_constraint "start_tick >= 0", name: "check_track_clips_start_tick_non_negative"
      t.check_constraint "(clip_kind = 'audio' AND audio_sample_id IS NOT NULL AND midi_clip_id IS NULL) OR (clip_kind = 'midi' AND midi_clip_id IS NOT NULL AND audio_sample_id IS NULL)", name: "check_track_clips_source_matches_kind"
    end

    create_table :automation_lanes do |t|
      t.uuid :uuid, null: false, default: -> { "gen_random_uuid()" }
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.references :track, null: true, foreign_key: { on_delete: :cascade }
      t.references :track_clip, null: true, foreign_key: { on_delete: :cascade }
      t.string :parameter_path, null: false
      t.float :min_value, default: 0.0, null: false
      t.float :max_value, default: 1.0, null: false
      t.jsonb :points_jsonb, default: [], null: false
      t.binary :points_binary
      t.boolean :bypassed, default: false, null: false
      t.jsonb :state_jsonb, default: {}, null: false
      t.integer :lock_version, default: 0, null: false

      t.timestamps

      t.index :uuid, unique: true
      t.index [ :track_id, :parameter_path ]
      t.check_constraint "max_value >= min_value", name: "check_automation_lanes_min_max_range"
    end
  end
end
