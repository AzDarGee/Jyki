# frozen_string_literal: true

class StudioAuthController < ApplicationController
  before_action :authenticate_user!

  # PATCH /studio_auth/identity — Inline @username update via Turbo Stream
  def update_identity
    identity_params = params.expect(user: [ :username, :display_name ])
    clean_username = identity_params[:username].to_s.strip.sub(/\A@/, "")

    if clean_username.present?
      current_user.username = clean_username
      current_user.display_name = identity_params[:display_name] if identity_params[:display_name].present?
      current_user.save
    end

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace(
            "top_bar_auth_badge",
            partial: "shared/top_bar_auth_badge",
            locals: { current_producer: current_user }
          ),
          turbo_stream.replace(
            "studio_auth_drawer",
            partial: "shared/studio_auth_drawer",
            locals: {
              current_producer: current_user,
              resource: current_user,
              auth_error: current_user.errors.full_messages.to_sentence.presence,
              active_auth_tab: "identity",
              open: true
            }
          )
        ]
      end
      format.html { redirect_to root_path }
    end
  end

  # PATCH /studio_auth/role_tier — Live Project Role & Studio Plan Tier update via Turbo Stream
  def update_role_tier
    role_params = params.expect(user: [ :project_role, :studio_plan ])

    if role_params[:project_role].present? && User::PROJECT_ROLES.key?(role_params[:project_role])
      current_user.project_role = role_params[:project_role]
      current_user.role = role_params[:project_role].upcase
    end

    if role_params[:studio_plan].present? && User::STUDIO_PLANS.key?(role_params[:studio_plan])
      current_user.studio_plan = role_params[:studio_plan]
      tier_map = {
        "studio_master" => "studio_master_192_64",
        "producer_pro" => "producer_pro_96_32",
        "indie_creator" => "indie_creator_48_24"
      }
      current_user.studio_plan_tier = tier_map[role_params[:studio_plan]]
    end

    current_user.save

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace(
            "top_bar_auth_badge",
            partial: "shared/top_bar_auth_badge",
            locals: { current_producer: current_user }
          ),
          turbo_stream.replace(
            "studio_auth_drawer",
            partial: "shared/studio_auth_drawer",
            locals: {
              current_producer: current_user,
              resource: current_user,
              auth_error: nil,
              active_auth_tab: "roles_acl",
              open: true
            }
          )
        ]
      end
      format.html { redirect_to root_path }
    end
  end

  # POST /studio_auth/collaborators — Grant collaborator ACL access via Turbo Stream
  def create_collaborator
    collab_params = params.expect(collaborator: [ :username, :email, :role ])
    clean_handle = collab_params[:username].to_s.strip.sub(/\A@/, "").downcase

    @collaborator = ProjectCollaborator.find_or_initialize_by(
      project_slug: "proj_default",
      username: clean_handle
    )
    @collaborator.email = collab_params[:email].presence || "#{clean_handle}@saanskara.studio"
    @collaborator.role = collab_params[:role].to_s.upcase.presence || "EDITOR"
    @collaborator.external_user_id = "usr_#{clean_handle}"
    @collaborator.added_at_label = "Added #{Time.current.utc.strftime('%H:%M')} UTC"
    @collaborator.save

    respond_to do |format|
      format.turbo_stream do
        if @collaborator.persisted?
          render turbo_stream: turbo_stream.append(
            "project_collaborators_list",
            partial: "studio_auth/collaborator",
            locals: { collaborator: @collaborator }
          )
        else
          head :unprocessable_content
        end
      end
      format.html { redirect_to root_path }
    end
  end

  # DELETE /studio_auth/collaborators/:id — Revoke collaborator ACL access via Turbo Stream
  def destroy_collaborator
    @collaborator = ProjectCollaborator.find_by(id: params[:id])
    dom_target = @collaborator ? ActionView::RecordIdentifier.dom_id(@collaborator) : nil
    @collaborator&.destroy

    respond_to do |format|
      format.turbo_stream do
        if dom_target
          render turbo_stream: turbo_stream.remove(dom_target)
        else
          head :ok
        end
      end
      format.html { redirect_to root_path }
    end
  end
end

