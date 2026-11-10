# frozen_string_literal: true

class CreateStudioChatMessagesAndCrdtBranches < ActiveRecord::Migration[8.1]
  def change
    create_table :studio_chat_messages do |t|
      t.string :sender_name, null: false, default: "Saanskara (Owner)"
      t.string :sender_role, null: false, default: "OWNER"
      t.text :body, null: false
      t.string :room_type, null: false, default: "project_room"
      t.string :recipient_handle
      t.string :sent_at_label, null: false, default: "17:12"

      t.timestamps
    end

    add_index :studio_chat_messages, :room_type

    create_table :crdt_branches do |t|
      t.string :name, null: false
      t.string :delta_vector, null: false
      t.string :committed_at_label, null: false, default: "17:12 UTC"

      t.timestamps
    end

    add_index :crdt_branches, :name
  end
end

