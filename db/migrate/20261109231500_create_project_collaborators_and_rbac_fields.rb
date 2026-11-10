# frozen_string_literal: true

class CreateProjectCollaboratorsAndRbacFields < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :display_name, :string, default: "Saanskara", null: false, if_not_exists: true
    add_column :users, :avatar_url, :string, if_not_exists: true
    add_column :users, :storage_node_id, :string, default: "4PS1G6fg...", null: false, if_not_exists: true
    add_column :users, :project_role, :string, default: "owner", null: false, if_not_exists: true
    add_column :users, :studio_plan, :string, default: "studio_master", null: false, if_not_exists: true

    create_table :project_collaborators, if_not_exists: true do |t|
      t.string :project_slug, null: false, default: "proj_default"
      t.string :username, null: false
      t.string :external_user_id, null: false
      t.string :email, null: false, default: ""
      t.string :role, null: false, default: "EDITOR"
      t.string :added_at_label, null: false, default: "Added 17:00 UTC"

      t.timestamps
    end

    add_index :project_collaborators, :project_slug, if_not_exists: true
    add_index :project_collaborators, [ :project_slug, :username ], unique: true, if_not_exists: true
  end
end

