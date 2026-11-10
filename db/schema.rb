# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_11_10_212114) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "audio_samples", force: :cascade do |t|
    t.uuid "uuid", default: -> { "gen_random_uuid()" }, null: false
    t.bigint "project_id"
    t.string "name", null: false
    t.string "storage_key"
    t.string "checksum_sha256"
    t.integer "sample_rate", default: 48000, null: false
    t.integer "channels", default: 2, null: false
    t.integer "bit_depth", default: 24, null: false
    t.bigint "total_frames", default: 0, null: false
    t.bigint "trim_start_frame", default: 0, null: false
    t.bigint "trim_end_frame"
    t.integer "duration_ms", default: 0, null: false
    t.decimal "detected_bpm", precision: 6, scale: 3
    t.string "detected_key"
    t.float "peak_db", default: 0.0
    t.float "integrated_lufs"
    t.boolean "is_loop", default: false, null: false
    t.binary "waveform_peaks_binary"
    t.jsonb "beatgrid_jsonb", default: [], null: false
    t.jsonb "cue_points_jsonb", default: [], null: false
    t.jsonb "dsp_metadata_jsonb", default: {}, null: false
    t.jsonb "state_jsonb", default: {}, null: false
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["checksum_sha256"], name: "index_audio_samples_on_checksum_sha256"
    t.index ["project_id"], name: "index_audio_samples_on_project_id"
    t.index ["storage_key"], name: "index_audio_samples_on_storage_key"
    t.index ["uuid"], name: "index_audio_samples_on_uuid", unique: true
    t.check_constraint "channels > 0", name: "check_audio_samples_channels_positive"
    t.check_constraint "sample_rate > 0", name: "check_audio_samples_sample_rate_positive"
    t.check_constraint "total_frames >= 0", name: "check_audio_samples_total_frames_non_negative"
  end

  create_table "automation_lanes", force: :cascade do |t|
    t.uuid "uuid", default: -> { "gen_random_uuid()" }, null: false
    t.bigint "project_id", null: false
    t.bigint "track_id"
    t.bigint "track_clip_id"
    t.string "parameter_path", null: false
    t.float "min_value", default: 0.0, null: false
    t.float "max_value", default: 1.0, null: false
    t.jsonb "points_jsonb", default: [], null: false
    t.binary "points_binary"
    t.boolean "bypassed", default: false, null: false
    t.jsonb "state_jsonb", default: {}, null: false
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id"], name: "index_automation_lanes_on_project_id"
    t.index ["track_clip_id"], name: "index_automation_lanes_on_track_clip_id"
    t.index ["track_id", "parameter_path"], name: "index_automation_lanes_on_track_id_and_parameter_path"
    t.index ["track_id"], name: "index_automation_lanes_on_track_id"
    t.index ["uuid"], name: "index_automation_lanes_on_uuid", unique: true
    t.check_constraint "max_value >= min_value", name: "check_automation_lanes_min_max_range"
  end

  create_table "crdt_branches", force: :cascade do |t|
    t.string "name", null: false
    t.string "delta_vector", null: false
    t.string "committed_at_label", default: "17:12 UTC", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_crdt_branches_on_name"
  end

  create_table "midi_clips", force: :cascade do |t|
    t.uuid "uuid", default: -> { "gen_random_uuid()" }, null: false
    t.bigint "project_id", null: false
    t.string "name", null: false
    t.bigint "length_ticks", default: 3840, null: false
    t.integer "note_count", default: 0, null: false
    t.jsonb "events_jsonb", default: [], null: false
    t.binary "events_binary"
    t.jsonb "groove_template_jsonb", default: {}, null: false
    t.jsonb "state_jsonb", default: {}, null: false
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id"], name: "index_midi_clips_on_project_id"
    t.index ["uuid"], name: "index_midi_clips_on_uuid", unique: true
    t.check_constraint "length_ticks > 0", name: "check_midi_clips_length_ticks_positive"
    t.check_constraint "note_count >= 0", name: "check_midi_clips_note_count_non_negative"
  end

  create_table "project_collaborators", force: :cascade do |t|
    t.string "project_slug", default: "proj_default", null: false
    t.string "username", null: false
    t.string "external_user_id", null: false
    t.string "email", default: "", null: false
    t.string "role", default: "EDITOR", null: false
    t.string "added_at_label", default: "Added 17:00 UTC", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["project_slug", "username"], name: "index_project_collaborators_on_project_slug_and_username", unique: true
    t.index ["project_slug"], name: "index_project_collaborators_on_project_slug"
  end

  create_table "projects", force: :cascade do |t|
    t.uuid "uuid", default: -> { "gen_random_uuid()" }, null: false
    t.bigint "user_id"
    t.bigint "crdt_branch_id"
    t.string "name", null: false
    t.string "slug"
    t.decimal "bpm", precision: 6, scale: 3, default: "120.0", null: false
    t.integer "time_signature_numerator", default: 4, null: false
    t.integer "time_signature_denominator", default: 4, null: false
    t.integer "ppqn", default: 960, null: false
    t.integer "sample_rate", default: 48000, null: false
    t.integer "root_note", default: 60
    t.string "scale_name", default: "chromatic"
    t.float "master_volume_db", default: 0.0, null: false
    t.float "swing_amount", default: 0.0, null: false
    t.string "workspace_mode", default: "daw", null: false
    t.string "theme_name", default: "midnight", null: false
    t.jsonb "settings_jsonb", default: {}, null: false
    t.jsonb "state_jsonb", default: {}, null: false
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["crdt_branch_id"], name: "index_projects_on_crdt_branch_id"
    t.index ["slug"], name: "index_projects_on_slug"
    t.index ["user_id"], name: "index_projects_on_user_id"
    t.index ["uuid"], name: "index_projects_on_uuid", unique: true
    t.check_constraint "bpm > 0::numeric", name: "check_projects_bpm_positive"
    t.check_constraint "ppqn > 0", name: "check_projects_ppqn_positive"
    t.check_constraint "sample_rate > 0", name: "check_projects_sample_rate_positive"
  end

  create_table "solid_cable_messages", force: :cascade do |t|
    t.binary "channel", null: false
    t.binary "payload", null: false
    t.datetime "created_at", null: false
    t.bigint "channel_hash", null: false
    t.index ["channel_hash"], name: "index_solid_cable_messages_on_channel_hash"
    t.index ["created_at"], name: "index_solid_cable_messages_on_created_at"
  end

  create_table "solid_cache_entries", force: :cascade do |t|
    t.binary "key", null: false
    t.binary "value", null: false
    t.datetime "created_at", null: false
    t.bigint "key_hash", null: false
    t.integer "byte_size", null: false
    t.index ["byte_size"], name: "index_solid_cache_entries_on_byte_size"
    t.index ["key_hash", "byte_size"], name: "index_solid_cache_entries_on_key_hash_and_byte_size"
    t.index ["key_hash"], name: "index_solid_cache_entries_on_key_hash", unique: true
  end

  create_table "solid_queue_batch_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.bigint "batch_id", null: false
    t.datetime "created_at", null: false
    t.index ["batch_id"], name: "index_solid_queue_batch_executions_on_batch_id"
    t.index ["job_id"], name: "index_solid_queue_batch_executions_on_job_id", unique: true
  end

  create_table "solid_queue_batches", force: :cascade do |t|
    t.string "active_job_batch_id"
    t.string "description"
    t.text "on_finish"
    t.text "on_success"
    t.text "on_failure"
    t.text "metadata"
    t.integer "total_jobs", default: 0, null: false
    t.integer "completed_jobs", default: 0, null: false
    t.integer "failed_jobs", default: 0, null: false
    t.datetime "enqueued_at"
    t.datetime "finished_at"
    t.datetime "failed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active_job_batch_id"], name: "index_solid_queue_batches_on_active_job_batch_id", unique: true
    t.index ["finished_at"], name: "index_solid_queue_batches_on_finished_at"
  end

  create_table "solid_queue_blocked_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.string "concurrency_key", null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.text "error"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", force: :cascade do |t|
    t.string "queue_name", null: false
    t.string "class_name", null: false
    t.text "arguments"
    t.integer "priority", default: 0, null: false
    t.string "active_job_id"
    t.datetime "scheduled_at"
    t.datetime "finished_at"
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "batch_id"
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["batch_id"], name: "index_solid_queue_jobs_on_batch_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", force: :cascade do |t|
    t.string "queue_name", null: false
    t.datetime "created_at", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", force: :cascade do |t|
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.bigint "supervisor_id"
    t.integer "pid", null: false
    t.string "hostname"
    t.text "metadata"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "task_key", null: false
    t.datetime "run_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", force: :cascade do |t|
    t.string "key", null: false
    t.string "schedule", null: false
    t.string "command", limit: 2048
    t.string "class_name"
    t.text "arguments"
    t.string "queue_name"
    t.integer "priority", default: 0
    t.boolean "static", default: true, null: false
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "scheduled_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", force: :cascade do |t|
    t.string "key", null: false
    t.integer "value", default: 1, null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  create_table "studio_chat_messages", force: :cascade do |t|
    t.string "sender_name", default: "Saanskara (Owner)", null: false
    t.string "sender_role", default: "OWNER", null: false
    t.text "body", null: false
    t.string "room_type", default: "project_room", null: false
    t.string "recipient_handle"
    t.string "sent_at_label", default: "17:12", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["room_type"], name: "index_studio_chat_messages_on_room_type"
  end

  create_table "track_clips", force: :cascade do |t|
    t.uuid "uuid", default: -> { "gen_random_uuid()" }, null: false
    t.bigint "project_id", null: false
    t.bigint "track_id", null: false
    t.string "clip_kind", null: false
    t.bigint "audio_sample_id"
    t.bigint "midi_clip_id"
    t.string "name"
    t.string "color_hex"
    t.integer "scene_slot_index"
    t.bigint "start_tick", default: 0, null: false
    t.bigint "duration_ticks", default: 3840, null: false
    t.bigint "source_offset_ticks", default: 0, null: false
    t.bigint "source_start_frame", default: 0, null: false
    t.bigint "source_end_frame"
    t.boolean "loop_enabled", default: false, null: false
    t.bigint "loop_start_tick", default: 0, null: false
    t.bigint "loop_end_tick", default: 3840, null: false
    t.float "gain_db", default: 0.0, null: false
    t.integer "transpose_semitones", default: 0, null: false
    t.float "detune_cents", default: 0.0, null: false
    t.boolean "warp_enabled", default: true, null: false
    t.string "warp_algorithm", default: "complex"
    t.float "time_stretch_ratio", default: 1.0, null: false
    t.bigint "fade_in_ticks", default: 0, null: false
    t.bigint "fade_out_ticks", default: 0, null: false
    t.float "fade_curve", default: 0.0, null: false
    t.boolean "muted", default: false, null: false
    t.jsonb "warp_markers_jsonb", default: [], null: false
    t.jsonb "state_jsonb", default: {}, null: false
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["audio_sample_id"], name: "index_track_clips_on_audio_sample_id"
    t.index ["midi_clip_id"], name: "index_track_clips_on_midi_clip_id"
    t.index ["project_id", "start_tick"], name: "index_track_clips_on_project_id_and_start_tick"
    t.index ["project_id"], name: "index_track_clips_on_project_id"
    t.index ["track_id", "start_tick", "duration_ticks"], name: "idx_on_track_id_start_tick_duration_ticks_235a3c35a4"
    t.index ["track_id"], name: "index_track_clips_on_track_id"
    t.index ["uuid"], name: "index_track_clips_on_uuid", unique: true
    t.check_constraint "clip_kind::text = 'audio'::text AND audio_sample_id IS NOT NULL AND midi_clip_id IS NULL OR clip_kind::text = 'midi'::text AND midi_clip_id IS NOT NULL AND audio_sample_id IS NULL", name: "check_track_clips_source_matches_kind"
    t.check_constraint "duration_ticks > 0", name: "check_track_clips_duration_ticks_positive"
    t.check_constraint "start_tick >= 0", name: "check_track_clips_start_tick_non_negative"
  end

  create_table "tracks", force: :cascade do |t|
    t.uuid "uuid", default: -> { "gen_random_uuid()" }, null: false
    t.bigint "project_id", null: false
    t.bigint "parent_bus_track_id"
    t.string "name", null: false
    t.string "track_type", default: "audio", null: false
    t.integer "deck_number"
    t.integer "position", default: 0, null: false
    t.string "color_hex", default: "#f59e0b", null: false
    t.float "volume_db", default: 0.0, null: false
    t.float "pan", default: 0.0, null: false
    t.boolean "muted", default: false, null: false
    t.boolean "soloed", default: false, null: false
    t.boolean "armed", default: false, null: false
    t.jsonb "input_routing_jsonb", default: {}, null: false
    t.jsonb "fx_chain_jsonb", default: [], null: false
    t.jsonb "state_jsonb", default: {}, null: false
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["parent_bus_track_id"], name: "index_tracks_on_parent_bus_track_id"
    t.index ["project_id", "deck_number"], name: "index_tracks_on_project_id_and_deck_number"
    t.index ["project_id", "position"], name: "index_tracks_on_project_id_and_position"
    t.index ["project_id"], name: "index_tracks_on_project_id"
    t.index ["uuid"], name: "index_tracks_on_uuid", unique: true
    t.check_constraint "deck_number IS NULL OR deck_number >= 1 AND deck_number <= 6", name: "check_tracks_deck_number_range"
    t.check_constraint "pan >= '-1.0'::numeric::double precision AND pan <= 1.0::double precision", name: "check_tracks_pan_range"
  end

  create_table "users", force: :cascade do |t|
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "reset_password_token"
    t.datetime "reset_password_sent_at"
    t.datetime "remember_created_at"
    t.integer "sign_in_count", default: 0, null: false
    t.datetime "current_sign_in_at"
    t.datetime "last_sign_in_at"
    t.string "current_sign_in_ip"
    t.string "last_sign_in_ip"
    t.string "confirmation_token"
    t.datetime "confirmed_at"
    t.datetime "confirmation_sent_at"
    t.string "unconfirmed_email"
    t.integer "failed_attempts", default: 0, null: false
    t.string "unlock_token"
    t.datetime "locked_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "username"
    t.string "studio_plan_tier", default: "studio_master_192_64", null: false
    t.string "role", default: "OWNER", null: false
    t.string "provider"
    t.string "uid"
    t.string "display_name", default: "Saanskara", null: false
    t.string "avatar_url"
    t.string "storage_node_id", default: "4PS1G6fg...", null: false
    t.string "project_role", default: "owner", null: false
    t.string "studio_plan", default: "studio_master", null: false
    t.index ["confirmation_token"], name: "index_users_on_confirmation_token", unique: true
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["provider", "uid"], name: "index_users_on_provider_and_uid"
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
    t.index ["unlock_token"], name: "index_users_on_unlock_token", unique: true
    t.index ["username"], name: "index_users_on_username", unique: true
  end

  add_foreign_key "audio_samples", "projects", on_delete: :nullify
  add_foreign_key "automation_lanes", "projects", on_delete: :cascade
  add_foreign_key "automation_lanes", "track_clips", on_delete: :cascade
  add_foreign_key "automation_lanes", "tracks", on_delete: :cascade
  add_foreign_key "midi_clips", "projects", on_delete: :cascade
  add_foreign_key "projects", "crdt_branches", on_delete: :nullify
  add_foreign_key "projects", "users", on_delete: :nullify
  add_foreign_key "solid_queue_batch_executions", "solid_queue_batches", column: "batch_id", on_delete: :cascade
  add_foreign_key "solid_queue_batch_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "track_clips", "audio_samples", on_delete: :restrict
  add_foreign_key "track_clips", "midi_clips", on_delete: :cascade
  add_foreign_key "track_clips", "projects", on_delete: :cascade
  add_foreign_key "track_clips", "tracks", on_delete: :cascade
  add_foreign_key "tracks", "projects", on_delete: :cascade
  add_foreign_key "tracks", "tracks", column: "parent_bus_track_id", on_delete: :nullify
end
