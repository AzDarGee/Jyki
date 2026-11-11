# frozen_string_literal: true

require "test_helper"

class CrdtSyncEngineTest < ActiveSupport::TestCase
  self.fixture_table_names = []

  setup do
    @project = StudioBootstrapper.ensure_default_project!
    @track = @project.tracks.order(:position).first
    @clip = @track.track_clips.order(:start_tick).first
  end

  test "generates, parses, and compares HLC timestamps deterministically" do
    hlc_t1 = CrdtSyncEngine.generate_hlc(node_id: "node_alpha", now_ms: 1_762_809_123_000)
    assert_equal "1762809123000-0000-node_alpha", hlc_t1

    # Advancing at the same wall clock millisecond increments the logical counter
    hlc_t2 = CrdtSyncEngine.generate_hlc(last_hlc: hlc_t1, node_id: "node_alpha", now_ms: 1_762_809_123_000)
    assert_equal "1762809123000-0001-node_alpha", hlc_t2

    parsed = CrdtSyncEngine.parse_hlc(hlc_t2)
    assert_equal 1_762_809_123_000, parsed[:wall_ms]
    assert_equal 1, parsed[:counter]
    assert_equal "node_alpha", parsed[:node_id]

    assert_equal 1, CrdtSyncEngine.compare_hlc(hlc_t2, hlc_t1)
    assert_equal(-1, CrdtSyncEngine.compare_hlc(hlc_t1, hlc_t2))
    assert_equal 0, CrdtSyncEngine.compare_hlc(hlc_t2, hlc_t2)
    assert_equal 1, CrdtSyncEngine.compare_hlc(hlc_t1, nil)
  end

  test "merges out-of-order concurrent HLC edits to distinct fields on Track and TrackClip without StaleObjectError" do
    # User A edits Track volume_db with a newer timestamp first
    res_a = CrdtSyncEngine.apply_delta!(
      @project,
      {
        op_id: "op_track_vol",
        origin_node_id: "node_a",
        actor: "aria_mastering",
        entity_type: "Track",
        entity_uuid: @track.uuid,
        action: "update",
        changes: { "volume_db" => -4.5 },
        hlc: "1762809123450-0001-node_a"
      }
    )
    assert res_a[:ok]
    assert res_a[:applied]

    # User B's edit to Track pan has an older HLC but arrives second (out-of-order network delivery)
    res_b = CrdtSyncEngine.apply_delta!(
      @project,
      {
        op_id: "op_track_pan",
        origin_node_id: "node_b",
        actor: "devon_synth",
        entity_type: "Track",
        entity_uuid: @track.uuid,
        action: "update",
        changes: { "pan" => 0.42 },
        hlc: "1762809123100-0000-node_b"
      }
    )
    assert res_b[:ok]
    assert res_b[:applied]

    @track.reload
    assert_in_delta(-4.5, @track.volume_db, 0.001)
    assert_in_delta(0.42, @track.pan, 0.001)
    assert_equal "1762809123450-0001-node_a", @track.state_jsonb.dig("hlc", "volume_db")
    assert_equal "1762809123100-0000-node_b", @track.state_jsonb.dig("hlc", "pan")
    assert_equal "devon_synth", @track.state_jsonb["last_actor"]

    # Simultaneous TrackClip edits to start_tick and gain_db out of order
    clip_res_a = CrdtSyncEngine.apply_delta!(
      @project,
      {
        op_id: "op_clip_move",
        origin_node_id: "node_a",
        actor: "aria_mastering",
        entity_type: "TrackClip",
        entity_uuid: @clip.uuid,
        action: "update",
        changes: { "start_tick" => 5760 },
        hlc: "1762809125000-0002-node_a"
      }
    )
    clip_res_b = CrdtSyncEngine.apply_delta!(
      @project,
      {
        op_id: "op_clip_gain",
        origin_node_id: "node_b",
        actor: "devon_synth",
        entity_type: "TrackClip",
        entity_uuid: @clip.uuid,
        action: "update",
        changes: { "gain_db" => 2.75 },
        hlc: "1762809124000-0000-node_b"
      }
    )

    assert clip_res_a[:applied]
    assert clip_res_b[:applied]
    @clip.reload
    assert_equal 5760, @clip.start_tick
    assert_in_delta 2.75, @clip.gain_db, 0.001
    assert_equal "1762809125000-0002-node_a", @clip.state_jsonb.dig("hlc", "start_tick")
    assert_equal "1762809124000-0000-node_b", @clip.state_jsonb.dig("hlc", "gain_db")
  end

  test "rejects stale HLC timestamps for a field while applying fresher fields in the same delta" do
    # Establish baseline watermarks: volume_db at t=5000, muted at t=2000
    CrdtSyncEngine.apply_delta!(
      @project,
      {
        op_id: "op_initial_vol",
        origin_node_id: "node_a",
        actor: "aria_mastering",
        entity_type: "Track",
        entity_uuid: @track.uuid,
        action: "update",
        changes: { "volume_db" => -2.0 },
        hlc: "1762809125000-0000-node_a"
      }
    )
    CrdtSyncEngine.apply_delta!(
      @project,
      {
        op_id: "op_initial_mute",
        origin_node_id: "node_b",
        actor: "devon_synth",
        entity_type: "Track",
        entity_uuid: @track.uuid,
        action: "update",
        changes: { "muted" => false },
        hlc: "1762809122000-0000-node_b"
      }
    )

    # Incoming packet at t=3000 is STALE for volume_db (< 5000) but FRESH for muted (> 2000)
    mixed_res = CrdtSyncEngine.apply_delta!(
      @project,
      {
        op_id: "op_mixed",
        origin_node_id: "node_b",
        actor: "devon_synth",
        entity_type: "Track",
        entity_uuid: @track.uuid,
        action: "update",
        changes: { "volume_db" => -12.0, "muted" => true },
        hlc: "1762809123000-0001-node_b"
      }
    )

    assert mixed_res[:ok]
    assert mixed_res[:applied]
    assert_equal({ "muted" => true }, mixed_res[:applied_changes])
    assert_includes mixed_res[:rejected_fields], "volume_db"

    @track.reload
    assert_in_delta(-2.0, @track.volume_db, 0.001)
    assert_equal true, @track.muted
  end

  test "records tombstone watermark on delete and ignores late updates with older HLC" do
    clip_uuid = @clip.uuid
    del_res = CrdtSyncEngine.apply_delta!(
      @project,
      {
        op_id: "op_del_clip",
        origin_node_id: "node_a",
        actor: "aria_mastering",
        entity_type: "TrackClip",
        entity_uuid: clip_uuid,
        action: "delete",
        hlc: "1762809130000-0000-node_a"
      }
    )
    assert del_res[:ok]
    assert del_res[:applied]
    assert_nil TrackClip.find_by(uuid: clip_uuid)
    assert_equal "1762809130000-0000-node_a", @project.reload.state_jsonb.dig("tombstones", clip_uuid)

    # Late-arriving update with older HLC is cleanly ignored
    late_res = CrdtSyncEngine.apply_delta!(
      @project,
      {
        op_id: "op_late_clip",
        origin_node_id: "node_b",
        actor: "devon_synth",
        entity_type: "TrackClip",
        entity_uuid: clip_uuid,
        action: "update",
        changes: { "start_tick" => 960 },
        hlc: "1762809129000-0000-node_b"
      }
    )
    assert late_res[:ok]
    assert_not late_res[:applied]
  end

  test "StudioBootstrapper seeds and serializes CRDT branch, collaborators, chat messages, and state_jsonb" do
    payload = StudioBootstrapper.serialize_project(@project)
    assert payload[:state_jsonb].is_a?(Hash)
    assert payload[:crdt_branch].present?
    assert payload[:branches].any?
    assert payload[:collaborators].any?
    assert payload[:chat_messages].any?
    assert payload[:tracks].first[:state_jsonb].is_a?(Hash)
    assert payload[:tracks].first[:clips].first[:state_jsonb].is_a?(Hash)
  end
end
