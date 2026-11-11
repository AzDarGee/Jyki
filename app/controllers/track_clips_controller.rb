# frozen_string_literal: true

class TrackClipsController < ApplicationController
  before_action :set_track, only: [ :create ]
  before_action :set_track_clip, only: [ :update, :destroy ]

  def create
    raw_params = track_clip_params.to_h.symbolize_keys
    inferred_kind = raw_params[:clip_kind].presence || (@track.midi? || @track.instrument? ? "midi" : "audio")
    raw_params[:clip_kind] = inferred_kind
    raw_params[:track_id] = @track.id
    raw_params[:start_tick] = (raw_params[:start_tick] || 0).to_i
    raw_params[:duration_ticks] = (raw_params[:duration_ticks].presence || 3840).to_i
    raw_params[:color_hex] ||= @track.color_hex
    bar_num = (raw_params[:start_tick] / 3840) + 1
    raw_params[:name] = "#{@track.name.sub(/^\d+\s*•\s*/, '')} • Bar #{bar_num}" if raw_params[:name].blank?

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
        entity_type: "TrackClip",
        entity_uuid: params[:uuid],
        action: "create",
        changes: raw_params,
        hlc: incoming_hlc
      }
    )
    StudioSyncChannel.broadcast_delta_ack(project, result)
    payload = result[:serialized_entity]

    respond_to do |format|
      format.json { render json: { ok: true, track_clip: payload, crdt: result }, status: :created }
      format.turbo_stream { render json: { ok: true, track_clip: payload, crdt: result }, status: :created }
    end
  rescue ActiveRecord::RecordInvalid => e
    render json: { ok: false, errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  def update
    project = @track_clip.project
    origin_node = params[:client_node_id].presence || request.headers["X-Saanskara-Node-Id"].presence || "rest_api"
    actor_handle = current_user&.username.presence || params[:actor].presence || "studio_rest"
    incoming_hlc = params[:hlc].presence || request.headers["X-Saanskara-Hlc"].presence || CrdtSyncEngine.generate_hlc(node_id: origin_node)

    result = CrdtSyncEngine.apply_delta!(
      project,
      {
        op_id: params[:op_id],
        origin_node_id: origin_node,
        actor: actor_handle,
        entity_type: "TrackClip",
        entity_uuid: @track_clip.uuid,
        entity_id: @track_clip.id,
        action: "update",
        changes: track_clip_params.to_h,
        hlc: incoming_hlc
      }
    )
    StudioSyncChannel.broadcast_delta_ack(project, result) if result[:applied]
    payload = result[:serialized_entity] || StudioBootstrapper.serialize_track_clip(@track_clip.reload)

    respond_to do |format|
      format.json { render json: { ok: true, track_clip: payload, crdt: result } }
      format.turbo_stream { render json: { ok: true, track_clip: payload, crdt: result } }
    end
  rescue ActiveRecord::RecordInvalid => e
    render json: { ok: false, errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  def destroy
    clip_id = @track_clip.id
    clip_uuid = @track_clip.uuid
    project = @track_clip.project
    origin_node = params[:client_node_id].presence || request.headers["X-Saanskara-Node-Id"].presence || "rest_api"
    actor_handle = current_user&.username.presence || params[:actor].presence || "studio_rest"
    incoming_hlc = params[:hlc].presence || request.headers["X-Saanskara-Hlc"].presence || CrdtSyncEngine.generate_hlc(node_id: origin_node)

    result = CrdtSyncEngine.apply_delta!(
      project,
      {
        op_id: params[:op_id],
        origin_node_id: origin_node,
        actor: actor_handle,
        entity_type: "TrackClip",
        entity_uuid: clip_uuid,
        entity_id: clip_id,
        action: "delete",
        hlc: incoming_hlc
      }
    )
    StudioSyncChannel.broadcast_delta_ack(project, result)

    respond_to do |format|
      format.json { render json: { ok: true, id: clip_id, uuid: clip_uuid, crdt: result } }
      format.turbo_stream { render json: { ok: true, id: clip_id, uuid: clip_uuid, crdt: result } }
    end
  end

  private

    def set_track
      @track = Track.includes(:project).find(params[:track_id])
    end

    def set_track_clip
      @track_clip = TrackClip.includes(:project, :track, :audio_sample, :midi_clip).find(params[:id])
    end

    def track_clip_params
      allowed = [
        :track_id,
        :clip_kind,
        :audio_sample_id,
        :midi_clip_id,
        :name,
        :color_hex,
        :scene_slot_index,
        :start_tick,
        :duration_ticks,
        :source_offset_ticks,
        :source_start_frame,
        :source_end_frame,
        :loop_enabled,
        :loop_start_tick,
        :loop_end_tick,
        :gain_db,
        :transpose_semitones,
        :detune_cents,
        :warp_enabled,
        :warp_algorithm,
        :time_stretch_ratio,
        :fade_in_ticks,
        :fade_out_ticks,
        :fade_curve,
        :muted
      ]

      if params[:track_clip].present?
        params.expect(track_clip: allowed)
      else
        params.permit(*allowed)
      end
    end
end
