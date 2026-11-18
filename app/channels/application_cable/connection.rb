# frozen_string_literal: true

module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user, :current_collaborator, :collaborator_profile

    PEER_PALETTE = [
      "#f59e0b",
      "#10b981",
      "#38bdf8",
      "#a855f7",
      "#ec4899",
      "#eab308",
      "#14b8a6",
      "#f97316"
    ].freeze

    def connect
      self.current_user = resolve_verified_user
      self.current_collaborator = build_collaborator_profile
      self.collaborator_profile = current_collaborator
    end

    private

      def resolve_verified_user
        warden_user = env["warden"]&.user
        return warden_user if warden_user.present?

        user_id = cookies.signed[:user_id] || cookies.encrypted[:user_id]
        User.find_by(id: user_id) if user_id.present?
      rescue StandardError
        nil
      end

      def build_collaborator_profile
        raw_node = request.params[:client_node_id].to_s.strip.presence ||
                   cookies[:saanskara_node_id].to_s.strip.presence ||
                   "node_#{SecureRandom.hex(3)}"
        node_id = raw_node.gsub(/[^a-zA-Z0-9_]/, "_")[0, 32]
        color_idx = Zlib.crc32(node_id) % PEER_PALETTE.size
        color_hex = PEER_PALETTE[color_idx]

        if current_user.present?
          handle = current_user.username.presence || current_user.email.to_s.split("@").first.presence || "producer"
          {
            node_id: node_id,
            username: handle.downcase,
            display_name: current_user.display_name.presence || handle.capitalize,
            role: (current_user.role.presence || "OWNER").upcase,
            color_hex: color_hex
          }
        else
          guest_suffix = node_id.split("_").last.to_s[0, 4].presence || "01"
          raw_guest = request.params[:guest_name].to_s.strip.presence || "studio_peer_#{guest_suffix}"
          username = raw_guest.gsub(/[^a-zA-Z0-9_]/, "_").downcase[0, 24]
          {
            node_id: node_id,
            username: username,
            display_name: raw_guest.tr("_", " "),
            role: "COLLABORATOR",
            color_hex: color_hex
          }
        end
      end
  end
end
