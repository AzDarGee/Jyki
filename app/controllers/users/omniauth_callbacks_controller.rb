# frozen_string_literal: true

class Users::OmniauthCallbacksController < Devise::OmniauthCallbacksController
  def google_oauth2
    auth = request.env["omniauth.auth"]

    if auth.blank?
      redirect_to root_path, alert: "Google authentication payload was missing."
      return
    end

    @user = User.from_omniauth(auth)

    if @user.persisted?
      sign_in(:user, @user, event: :authentication)
      set_flash_message(:notice, :success, kind: "Google") if is_navigational_format?
      redirect_to root_path
    else
      session["devise.google_data"] = auth.except("extra")
      redirect_to root_path, alert: @user.errors.full_messages.to_sentence.presence || "Could not authenticate with Google."
    end
  end

  def failure
    redirect_to root_path, alert: "Google authentication failed: #{failure_message}"
  end
end
