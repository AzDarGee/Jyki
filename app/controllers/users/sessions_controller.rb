# frozen_string_literal: true

class Users::SessionsController < Devise::SessionsController
  before_action :configure_sign_in_params, only: [ :create ]

  # POST /users/sign_in — Zero-redirect Turbo Stream authentication via email or username
  def create
    user_params = params[:user] || {}
    login_identifier = (user_params[:login].presence || user_params[:email].presence || user_params[:username].presence).to_s.strip
    password_input = user_params[:password].to_s

    user = User.find_for_database_authentication(login: login_identifier)

    if user&.valid_password?(password_input)
      sign_in(:user, user)
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: [
            turbo_stream.replace(
              "top_bar_auth_badge",
              partial: "shared/top_bar_auth_badge",
              locals: { current_producer: user }
            ),
            turbo_stream.replace(
              "studio_auth_drawer",
              partial: "shared/studio_auth_drawer",
              locals: {
                current_producer: user,
                resource: user,
                auth_error: nil,
                active_tab: "signin",
                open: true
              }
            )
          ]
        end
        format.html { redirect_to root_path }
      end
    else
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            "studio_auth_drawer",
            partial: "shared/studio_auth_drawer",
            locals: {
              current_producer: nil,
              resource: User.new(login: login_identifier),
              auth_error: "Invalid studio username/email or password.",
              active_tab: "signin",
              open: true
            }
          ), status: :unprocessable_content
        end
        format.html do
          render partial: "shared/studio_auth_drawer",
                 locals: {
                   current_producer: nil,
                   resource: User.new(login: login_identifier),
                   auth_error: "Invalid studio username/email or password.",
                   active_tab: "signin",
                   open: true
                 },
                 status: :unprocessable_content
        end
      end
    end
  end

  # DELETE /users/sign_out — Zero-redirect Turbo Stream sign-out in-place
  def destroy
    sign_out(:user)
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.replace(
            "top_bar_auth_badge",
            partial: "shared/top_bar_auth_badge",
            locals: { current_producer: nil }
          ),
          turbo_stream.replace(
            "studio_auth_drawer",
            partial: "shared/studio_auth_drawer",
            locals: {
              current_producer: nil,
              resource: User.new,
              auth_error: nil,
              active_tab: "signup",
              open: false
            }
          )
        ]
      end
      format.html { redirect_to root_path }
    end
  end

  protected

    def configure_sign_in_params
      devise_parameter_sanitizer.permit(:sign_in, keys: [ :login, :username, :email ])
    end
end
