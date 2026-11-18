# frozen_string_literal: true

require "test_helper"

class ApplicationCableConnectionTest < ActionCable::Connection::TestCase
  tests ApplicationCable::Connection
  self.fixture_table_names = []

  test "connects with deterministic guest collaborator profile from client_node_id" do
    connect params: { client_node_id: "node_tab_01", guest_name: "Aria_Guest" }

    assert_equal "node_tab_01", connection.collaborator_profile[:node_id]
    assert_equal "aria_guest", connection.collaborator_profile[:username]
    assert connection.collaborator_profile[:color_hex].present?
  end
end

class StudioSyncChannelTest < ActionCable::Channel::TestCase
  self.fixture_table_names = []

  setup do
    @project = StudioBootstrapper.ensure_default_project!
    @track = @project.tracks.order(:position).first
    @clip = @track.track_clips.order(:start_tick).first
    @stream_name = "studio_project_#{@project.uuid}"

    stub_connection(
      current_user: nil,
      collaborator_profile: {
        node_id: "node_peer_1",
        username: "aria_mastering",
        display_name: "Aria (Mastering)",
        role: "EDITOR",
        color_hex: "#10b981"
      }
    )
  end

  test "subscribes to project stream and broadcasts presence_join and presence_leave" do
    assert_broadcasts(@stream_name, 1) do
      subscribe(project_uuid: @project.uuid, client_node_id: "node_peer_1")
    end

    assert subscription.confirmed?
    assert_has_stream @stream_name

    assert_broadcasts(@stream_name, 1) do
      unsubscribe
    end
  end

  test "crdt_delta applies HLC LWW mutation to PostgreSQL and broadcasts crdt_delta_ack" do
    subscribe(project_uuid: @project.uuid, client_node_id: "node_peer_1")

    assert_broadcasts(@stream_name, 1) do
      perform :crdt_delta, {
        op_id: "op_ws_vol_1",
        origin_node_id: "node_peer_1",
        actor: "aria_mastering",
        entity_type: "Track",
        entity_uuid: @track.uuid,
        action: "update",
        changes: { "volume_db" => -6.25, "soloed" => true },
        hlc: "1762809150000-0001-node_peer_1"
      }
    end

    @track.reload
    assert_in_delta(-6.25, @track.volume_db, 0.001)
    assert_equal true, @track.soloed
    assert_equal "1762809150000-0001-node_peer_1", @track.state_jsonb.dig("hlc", "volume_db")
  end

  test "ephemeral_telemetry broadcasts cursor and fader state with zero database writes" do
    subscribe(project_uuid: @project.uuid, client_node_id: "node_peer_1")

    assert_no_difference -> { Track.count + TrackClip.count + StudioChatMessage.count } do
      assert_broadcasts(@stream_name, 1) do
        perform :ephemeral_telemetry, {
          cursor_tick: 7680,
          cursor_track_uuid: @track.uuid,
          dragging_clip_uuid: @clip.uuid,
          preview_start_tick: 11520,
          live_fader: { track_uuid: @track.uuid, volume_db: -3.2, pan: -0.1 }
        }
      end
    end
  end

  test "chat_message and switch_or_snapshot_branch persist and broadcast to studio peers" do
    subscribe(project_uuid: @project.uuid, client_node_id: "node_peer_1")

    assert_difference -> { StudioChatMessage.count }, 1 do
      assert_broadcasts(@stream_name, 1) do
        perform :chat_message, {
          body: "Locking Sitar transient bus at -1.5dB",
          sender_name: "Aria (Mastering)",
          sender_role: "EDITOR"
        }
      end
    end

    assert_difference -> { CrdtBranch.count }, 1 do
      assert_broadcasts(@stream_name, 1) do
        perform :switch_or_snapshot_branch, {
          branch_name: "sitar-stem-v2"
        }
      end
    end

    assert_equal "sitar-stem-v2", @project.reload.crdt_branch.name
  end
end
