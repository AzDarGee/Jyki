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
    @branches = CrdtBranch.default_branches
    @active_branch = @project.crdt_branch || @branches.first
    slug_scope = [ @project.slug, "proj_default" ].compact.uniq
    @collaborators = ProjectCollaborator.where(project_slug: slug_scope).order(:id).to_a
    @collaborators = ProjectCollaborator.default_roster_for("proj_default") if @collaborators.empty?
    @chat_messages = StudioChatMessage.where(room_type: "project_room").order(:id).last(30)
    @chat_messages = StudioChatMessage.default_messages_for("project_room") if @chat_messages.empty?
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
