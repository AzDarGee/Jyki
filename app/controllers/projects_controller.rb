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
    if @project.update(project_params)
      payload = StudioBootstrapper.serialize_project(@project)
      respond_to do |format|
        format.json { render json: { ok: true, project: payload } }
        format.turbo_stream { render json: { ok: true, project: payload } }
        format.html { redirect_to home_path(project_id: @project.id) }
      end
    else
      render json: { ok: false, errors: @project.errors.full_messages }, status: :unprocessable_entity
    end
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
