# frozen_string_literal: true

class AddStudioAuthFieldsToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :username, :string, if_not_exists: true
    add_column :users, :studio_plan_tier, :string, default: "studio_master_192_64", null: false, if_not_exists: true
    add_column :users, :role, :string, default: "OWNER", null: false, if_not_exists: true
    add_column :users, :provider, :string, if_not_exists: true
    add_column :users, :uid, :string, if_not_exists: true

    add_index :users, :username, unique: true, if_not_exists: true
    add_index :users, [ :provider, :uid ], if_not_exists: true
  end
end

