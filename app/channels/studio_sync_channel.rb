# frozen_string_literal: true

class StudioSyncChannel < ApplicationCable::Channel
  def subscribed
    @project = resolve_project
    if @project.nil?
      reject
      return
    end

    @stream_name = self.class.stream_name_for(@project)
    stream_from @stream_name

    ActionCable.server.broadcast(
      @stream_name,
      {
        type: "presence_join",
        peer: peer_metadata,
        branch: CrdtSyncEngine.serialize_branch(@project.crdt_branch),
        timestamp_ms: (Time.current.to_f * 1000).to_i
      }
    )
  end

  def unsubscribed
    return if @stream_name.blank?

    ActionCable.server.broadcast(
      @stream_name,
      {
        type: "presence_leave",
        peer: peer_metadata,
        timestamp_ms: (Time.current.to_f * 1000).to_i
      }
    )
  end

  def crdt_delta(data)
    return if @project.nil?

    payload = data.to_h.with_indifferent_access
    payload[:origin_node_id] ||= peer_metadata[:node_id]
    payload[:actor] ||= peer_metadata[:username]

    result = CrdtSyncEngine.apply_delta!(@project, payload)
    self.class.broadcast_delta_ack(@project, result, peer_metadata)
  end

  def ephemeral_telemetry(data)
    return if @stream_name.blank?

    payload = data.to_h.with_indifferent_access
    ActionCable.server.broadcast(
      @stream_name,
      {
        type: "ephemeral_telemetry",
        origin_node_id: payload[:node_id].presence || peer_metadata[:node_id],
        username: payload[:username].presence || peer_metadata[:username],
        display_name: peer_metadata[:display_name],
        color_hex: payload[:color_hex].presence || peer_metadata[:color_hex],
        cursor_tick: payload[:cursor_tick]&.to_i,
        cursor_track_uuid: payload[:cursor_track_uuid],
        dragging_clip_uuid: payload[:dragging_clip_uuid],
        preview_start_tick: payload[:preview_start_tick]&.to_i,
        preview_duration_ticks: payload[:preview_duration_ticks]&.to_i,
        live_fader: payload[:live_fader],
        transport: payload[:transport],
        timestamp_ms: (Time.current.to_f * 1000).to_i
      }
    )
  end

  def chat_message(data)
    return if @project.nil?

    payload = data.to_h.with_indifferent_access
    body = payload[:body].to_s.strip
    return if body.blank?

    message = StudioChatMessage.create!(
      sender_name: payload[:sender_name].presence || peer_metadata[:display_name] || peer_metadata[:username],
      sender_role: payload[:sender_role].presence || peer_metadata[:role] || "COLLABORATOR",
      body: body,
      room_type: payload[:room_type].presence || "project_room",
      recipient_handle: payload[:recipient_handle].presence || peer_metadata[:username]
    )

    ActionCable.server.broadcast(
      @stream_name,
      {
        type: "chat_message",
        origin_node_id: peer_metadata[:node_id],
        message: StudioBootstrapper.serialize_chat_message(message)
      }
    )
  end

  def add_collaborator(data)
    return if @project.nil?

    payload = data.to_h.with_indifferent_access
    raw_username = payload[:username].to_s.strip
    return if raw_username.blank?

    slug = @project.slug.presence || "proj_default"
    collaborator = ProjectCollaborator.find_or_initialize_by(
      project_slug: slug,
      username: raw_username.sub(/\A@/, "").downcase
    )
    collaborator.role = payload[:role].to_s.upcase.presence || "COLLABORATOR"
    collaborator.email = payload[:email].presence if payload[:email].present?
    collaborator.save!

    ActionCable.server.broadcast(
      @stream_name,
      {
        type: "collaborator_added",
        origin_node_id: peer_metadata[:node_id],
        collaborator: StudioBootstrapper.serialize_collaborator(collaborator)
      }
    )
  end

  def switch_or_snapshot_branch(data)
    return if @project.nil?

    payload = data.to_h.with_indifferent_access
    branch_name = payload[:branch_name].to_s.strip.presence || "snapshot-#{Time.current.utc.strftime('%H%M%S')}"
    hlc = payload[:hlc].presence || CrdtSyncEngine.generate_hlc(node_id: peer_metadata[:node_id])
    short_hlc = hlc.to_s.split("-").first(2).join("-")
    encoded = Base64.strict_encode64("branch:#{branch_name}:#{short_hlc}")[0, 22]

    branch = CrdtBranch.find_or_initialize_by(name: branch_name)
    branch.delta_vector = "AQt/#{encoded}=="
    branch.committed_at_label = "#{Time.current.utc.strftime('%H:%M:%S')} UTC"
    branch.save!

    @project.update_column(:crdt_branch_id, branch.id)
    @project.crdt_branch = branch

    ActionCable.server.broadcast(
      @stream_name,
      {
        type: "branch_switched",
        origin_node_id: peer_metadata[:node_id],
        actor: peer_metadata[:username],
        hlc: hlc,
        branch: CrdtSyncEngine.serialize_branch(branch),
        branches: CrdtBranch.order(:id).map { |b| CrdtSyncEngine.serialize_branch(b) }
      }
    )
  end

  class << self
    def stream_name_for(project)
      "studio_project_#{project.uuid}"
    end

    def broadcast_delta_ack(project, result, peer = nil)
      return if project.nil? || result.nil?

      ActionCable.server.broadcast(
        stream_name_for(project),
        {
          type: "crdt_delta_ack",
          ok: result[:ok],
          applied: result[:applied],
          op_id: result[:op_id],
          origin_node_id: result[:origin_node_id],
          actor: result[:actor],
          peer: peer,
          entity_type: result[:entity_type],
          entity_uuid: result[:entity_uuid],
          entity_id: result[:entity_id],
          action: result[:action],
          applied_changes: result[:applied_changes],
          rejected_fields: result[:rejected_fields],
          hlc: result[:hlc],
          state_jsonb: result[:state_jsonb],
          serialized_entity: result[:serialized_entity],
          branch: result[:branch]
        }
      )
    end
  end

  private

    def resolve_project
      uuid = params[:project_uuid].to_s.strip.presence
      if uuid.present?
        found = Project.find_by(uuid: uuid)
        return found if found
      end

      if params[:project_id].present?
        found = Project.find_by(id: params[:project_id])
        return found if found
      end

      Project.first || StudioBootstrapper.ensure_default_project!
    end

    def peer_metadata
      base = (respond_to?(:current_collaborator) && current_collaborator).presence ||
             (respond_to?(:collaborator_profile) && collaborator_profile).presence || {
        node_id: "node_guest",
        username: "studio_guest",
        display_name: "Studio Guest",
        role: "COLLABORATOR",
        color_hex: "#38bdf8"
      }

      if params[:client_node_id].present?
        custom_node = params[:client_node_id].to_s.gsub(/[^a-zA-Z0-9_]/, "_")[0, 32]
        base = base.merge(node_id: custom_node) if custom_node.present?
      end

      base
    end
end
