# frozen_string_literal: true

class ProjectsController < ApplicationController
  before_action :set_project

  def show
    @tracks = @project.tracks.sort_by { |t| [ t.position, t.id ] }
    @studio_payload = StudioBootstrapper.serialize_project(@project)
    @studio_payload_json = @studio_payload.to_json

    respond_to do |format|
      format.html { render "home/index" }
      format.json { render json: { ok: true, project: @studio_payload } }
    end
  end

  def update
    raw_changes = project_params.to_h
    origin_node = params[:client_node_id].presence || request.headers["X-Saanskara-Node-Id"].presence || "rest_api"
    actor_handle = current_user&.username.presence || params[:actor].presence || "studio_rest"
    incoming_hlc = params[:hlc].presence || request.headers["X-Saanskara-Hlc"].presence || CrdtSyncEngine.generate_hlc(node_id: origin_node)

    result = CrdtSyncEngine.apply_delta!(
      @project,
      {
        op_id: params[:op_id],
        origin_node_id: origin_node,
        actor: actor_handle,
        entity_type: "Project",
        entity_uuid: @project.uuid,
        action: "update",
        changes: raw_changes,
        hlc: incoming_hlc
      }
    )
    StudioSyncChannel.broadcast_delta_ack(@project, result) if result[:applied]

    payload = StudioBootstrapper.serialize_project(@project.reload)
    respond_to do |format|
      format.json { render json: { ok: true, project: payload, crdt: result } }
      format.turbo_stream { render json: { ok: true, project: payload, crdt: result } }
      format.html { redirect_to home_path(project_id: @project.id) }
    end
  rescue ActiveRecord::RecordInvalid => e
    render json: { ok: false, errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  private

    def set_project
      @project = StudioBootstrapper.load_full_project(params[:id])
    end

    def project_params
      allowed = [
        :name,
        :bpm,
        :time_signature_numerator,
        :time_signature_denominator,
        :ppqn,
        :sample_rate,
        :root_note,
        :scale_name,
        :master_volume_db,
        :swing_amount,
        :workspace_mode,
        :theme_name,
        { settings_jsonb: {} }
      ]

      if params[:project].present?
        params.expect(project: allowed)
      else
        params.permit(*allowed)
      end
    end
end
