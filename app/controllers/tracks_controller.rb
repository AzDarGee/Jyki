# frozen_string_literal: true

class TracksController < ApplicationController
  before_action :set_project, only: [ :create ]
  before_action :set_track, only: [ :update, :destroy ]

  PALETTE = [ "#f59e0b", "#10b981", "#38bdf8", "#a855f7", "#ec4899", "#eab308", "#14b8a6", "#f97316" ].freeze

  def create
    next_pos = (@project.tracks.maximum(:position) || -1) + 1
    next_num = @project.tracks.count + 1
    raw_params = track_params.to_h.symbolize_keys

    track_type = raw_params[:track_type].presence || "audio"
    default_name = format("%02d • %s Track", next_num, track_type.capitalize)
    default_color = PALETTE[next_pos % PALETTE.size]
    default_deck = next_num <= 6 ? next_num : nil

    changes = raw_params.dup
    changes[:name] = default_name if changes[:name].blank?
    changes[:track_type] = track_type
    changes[:position] = next_pos if changes[:position].nil?
    changes[:color_hex] = default_color if changes[:color_hex].blank?
    if changes[:deck_number].nil? && default_deck && !@project.tracks.exists?(deck_number: default_deck)
      changes[:deck_number] = default_deck
    end

    origin_node = params[:client_node_id].presence || request.headers["X-Saanskara-Node-Id"].presence || "rest_api"
    actor_handle = current_user&.username.presence || params[:actor].presence || "studio_rest"
    incoming_hlc = params[:hlc].presence || request.headers["X-Saanskara-Hlc"].presence || CrdtSyncEngine.generate_hlc(node_id: origin_node)

    result = CrdtSyncEngine.apply_delta!(
      @project,
      {
        op_id: params[:op_id],
        origin_node_id: origin_node,
        actor: actor_handle,
        entity_type: "Track",
        entity_uuid: params[:uuid],
        action: "create",
        changes: changes,
        hlc: incoming_hlc
      }
    )
    StudioSyncChannel.broadcast_delta_ack(@project, result)
    payload = result[:serialized_entity]

    respond_to do |format|
      format.json { render json: { ok: true, track: payload, crdt: result }, status: :created }
      format.turbo_stream { render json: { ok: true, track: payload, crdt: result }, status: :created }
    end
  rescue ActiveRecord::RecordInvalid => e
    render json: { ok: false, errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  def update
    project = @track.project
    origin_node = params[:client_node_id].presence || request.headers["X-Saanskara-Node-Id"].presence || "rest_api"
    actor_handle = current_user&.username.presence || params[:actor].presence || "studio_rest"
    incoming_hlc = params[:hlc].presence || request.headers["X-Saanskara-Hlc"].presence || CrdtSyncEngine.generate_hlc(node_id: origin_node)

    result = CrdtSyncEngine.apply_delta!(
      project,
      {
        op_id: params[:op_id],
        origin_node_id: origin_node,
        actor: actor_handle,
        entity_type: "Track",
        entity_uuid: @track.uuid,
        entity_id: @track.id,
        action: "update",
        changes: track_params.to_h,
        hlc: incoming_hlc
      }
    )
    StudioSyncChannel.broadcast_delta_ack(project, result) if result[:applied]
    payload = result[:serialized_entity] || StudioBootstrapper.serialize_track(@track.reload)

    respond_to do |format|
      format.json { render json: { ok: true, track: payload, crdt: result } }
      format.turbo_stream { render json: { ok: true, track: payload, crdt: result } }
    end
  rescue ActiveRecord::RecordInvalid => e
    render json: { ok: false, errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  def destroy
    track_id = @track.id
    track_uuid = @track.uuid
    project = @track.project
    origin_node = params[:client_node_id].presence || request.headers["X-Saanskara-Node-Id"].presence || "rest_api"
    actor_handle = current_user&.username.presence || params[:actor].presence || "studio_rest"
    incoming_hlc = params[:hlc].presence || request.headers["X-Saanskara-Hlc"].presence || CrdtSyncEngine.generate_hlc(node_id: origin_node)

    result = CrdtSyncEngine.apply_delta!(
      project,
      {
        op_id: params[:op_id],
        origin_node_id: origin_node,
        actor: actor_handle,
        entity_type: "Track",
        entity_uuid: track_uuid,
        entity_id: track_id,
        action: "delete",
        hlc: incoming_hlc
      }
    )
    StudioSyncChannel.broadcast_delta_ack(project, result)

    respond_to do |format|
      format.json { render json: { ok: true, id: track_id, uuid: track_uuid, crdt: result } }
      format.turbo_stream { render json: { ok: true, id: track_id, uuid: track_uuid, crdt: result } }
    end
  end

  private

    def set_project
      @project = Project.find(params[:project_id])
    end

    def set_track
      @track = Track.includes(:project, track_clips: [ :audio_sample, :midi_clip ]).find(params[:id])
    end

    def track_params
      allowed = [
        :name,
        :track_type,
        :deck_number,
        :position,
        :color_hex,
        :volume_db,
        :pan,
        :muted,
        :soloed,
        :armed,
        :parent_bus_track_id
      ]

      if params[:track].present?
        params.expect(track: allowed)
      else
        params.permit(*allowed)
      end
    end
end
