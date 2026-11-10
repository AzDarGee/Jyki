# frozen_string_literal: true

class Users::RegistrationsController < Devise::RegistrationsController
  before_action :configure_sign_up_params, only: [ :create ]
  before_action :configure_account_update_params, only: [ :update ]

  # POST /users — Zero-redirect Turbo Stream registration inside Studio Auth drawer
  def create
    build_resource(sign_up_params)
    resource.skip_confirmation! if resource.respond_to?(:skip_confirmation!)
    resource.save

    if resource.persisted?
      sign_up(resource_name, resource)
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: [
            turbo_stream.replace(
              "top_bar_auth_badge",
              partial: "shared/top_bar_auth_badge",
              locals: { current_producer: resource }
            ),
            turbo_stream.replace(
              "studio_auth_drawer",
              partial: "shared/studio_auth_drawer",
              locals: {
                current_producer: resource,
                resource: resource,
                auth_error: nil,
                active_tab: "signup",
                open: true
              }
            )
          ]
        end
        format.html { redirect_to root_path }
      end
    else
      clean_up_passwords resource
      set_minimum_password_length
      error_msg = resource.errors.full_messages.to_sentence.presence || "Could not register producer account."

      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            "studio_auth_drawer",
            partial: "shared/studio_auth_drawer",
            locals: {
              current_producer: nil,
              resource: resource,
              auth_error: error_msg,
              active_tab: "signup",
              open: true
            }
          ), status: :unprocessable_content
        end
        format.html do
          render partial: "shared/studio_auth_drawer",
                 locals: {
                   current_producer: nil,
                   resource: resource,
                   auth_error: error_msg,
                   active_tab: "signup",
                   open: true
                 },
                 status: :unprocessable_content
        end
      end
    end
  end

  protected

    def configure_sign_up_params
      devise_parameter_sanitizer.permit(:sign_up, keys: [ :username, :studio_plan_tier, :role ])
    end

    def configure_account_update_params
      devise_parameter_sanitizer.permit(:account_update, keys: [ :username, :studio_plan_tier, :role ])
    end
end
