# frozen_string_literal: true

class HomeController < ApplicationController
  before_action :set_isolation_headers

  def index
    @project = if params[:project_id].present?
      StudioBootstrapper.load_full_project(params[:project_id])
    else
      StudioBootstrapper.ensure_default_project!
    end
    @tracks = @project.tracks.sort_by { |t| [ t.position, t.id ] }
    @studio_payload = StudioBootstrapper.serialize_project(@project)
    @studio_payload_json = @studio_payload.to_json

    respond_to do |format|
      format.html
      format.json { render json: { ok: true, project: @studio_payload } }
    end
  end

  private

    def set_isolation_headers
      response.set_header("Cross-Origin-Opener-Policy", "same-origin")
      response.set_header("Cross-Origin-Embedder-Policy", "credentialless")
      response.set_header("Cross-Origin-Resource-Policy", "same-origin")
    end
end
