# frozen_string_literal: true

class StudioChatMessage < ApplicationRecord
  ROOM_TYPES = [ "project_room", "dm" ].freeze

  validates :sender_name, presence: true
  validates :body, presence: true, length: { maximum: 1000 }
  validates :room_type, inclusion: { in: ROOM_TYPES }

  before_validation :ensure_message_defaults

  after_create_commit -> {
    broadcast_append_to(
      "jyki_project_chat",
      target: "jyki_chat_messages",
      partial: "workstation/sidebar/chat_message",
      locals: { message: self }
    )
  }

  def self.default_messages_for(room_type = "project_room")
    existing = where(room_type: room_type).order(:id).to_a
    return existing if existing.any?

    [
      create!(
        sender_name: "Aria (Mastering Eng)",
        sender_role: "EDITOR",
        body: "Checked the 96kHz / 32-bit float bounce—sub phase is rock solid below 60Hz.",
        room_type: "project_room",
        recipient_handle: "aria_mastering",
        sent_at_label: "17:08"
      ),
      create!(
        sender_name: "Devon (Synth Lead)",
        sender_role: "COLLABORATOR",
        body: "Committed branch alt-808-saturation-pass with Yjs delta vector update.",
        room_type: "project_room",
        recipient_handle: "devon_synth",
        sent_at_label: "17:11"
      )
    ]
  rescue ActiveRecord::RecordInvalid
    where(room_type: room_type).order(:id).to_a
  end

  private

    def ensure_message_defaults
      self.sender_name = "Saanskara (Owner)" if sender_name.blank?
      self.sender_role = "OWNER" if sender_role.blank?
      self.room_type = "project_room" unless ROOM_TYPES.include?(room_type)
      self.sent_at_label = Time.current.utc.strftime("%H:%M") if sent_at_label.blank?
    end
end

