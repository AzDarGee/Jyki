# frozen_string_literal: true

class Users::OmniauthCallbacksController < Devise::OmniauthCallbacksController
  def google_oauth2
    @user = User.from_omniauth(request.env["omniauth.auth"])

    if @user.persisted?
      sign_in(:user, @user, event: :authentication)
    end

    redirect_to root_path
  end

  def failure
    redirect_to root_path
  end
end
