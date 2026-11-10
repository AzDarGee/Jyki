# frozen_string_literal: true

class TurboFailureApp < Devise::FailureApp
  def respond
    if request_format == :turbo_stream || request.headers["Turbo-Frame"].present? || request.headers["X-Jaku-SPA"].present?
      render_studio_auth_failure
    else
      super
    end
  end

  def redirect_url
    root_path
  end

  private

    def render_studio_auth_failure
      self.status = 422
      self.content_type = "text/vnd.turbo-stream.html"
      self.response_body = ApplicationController.render(
        inline: <<~ERB,
          <%= turbo_stream.replace(
                "studio_auth_drawer",
                partial: "shared/studio_auth_drawer",
                locals: {
                  current_producer: nil,
                  resource: User.new,
                  auth_error: i18n_message(:invalid),
                  active_tab: "signin",
                  open: true
                }
              ) %>
        ERB
      )
    end
end

