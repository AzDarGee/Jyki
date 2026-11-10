# frozen_string_literal: true

require "test_helper"

class UserTest < ActiveSupport::TestCase
  self.fixture_table_names = []

  test "sets default studio_plan_tier, project_role, studio_plan, and role and validates username" do
    user = User.new(
      username: "saanskara",
      display_name: "Saanskara",
      email: "saanskarastudios@gmail.com",
      password: "Password123!",
      password_confirmation: "Password123!"
    )
    assert user.valid?
    assert_equal "studio_master_192_64", user.studio_plan_tier
    assert_equal "studio_master", user.studio_plan
    assert_equal "owner", user.project_role
    assert_equal "OWNER", user.role
    assert_equal "GOOGLE.COM", user.provider
    assert_equal "4PS1G6fg...", user.storage_node_id
    assert_equal "SA", user.initials
    assert_equal "Studio Master (192kHz / 64-bit)", user.studio_plan_label
  end

  test "computes 7 effective_permissions dynamically from project_role and studio_plan" do
    user = User.new(
      username: "saanskara",
      email: "saanskarastudios@gmail.com",
      password: "Password123!",
      project_role: "owner",
      studio_plan: "studio_master"
    )
    perms = user.effective_permissions
    assert_equal 7, perms.size
    assert perms.all? { |p| p[:status] == "GRANTED" }

    user.project_role = "viewer"
    user.studio_plan = "indie_creator"
    restricted_perms = user.effective_permissions
    acl_perm = restricted_perms.find { |p| p[:label] == "Project Collaborator ACL Management" }
    stem_perm = restricted_perms.find { |p| p[:label] == "96kHz / 192kHz Lossless Stem Export" }
    assert_not_equal "GRANTED", acl_perm[:status]
    assert_not_equal "GRANTED", stem_perm[:status]
  end

  test "requires unique username and email" do
    user = User.new(username: "", email: "", password: "Password123!")
    assert_not user.valid?
    assert_includes user.errors[:username], "can't be blank"
    assert_includes user.errors[:email], "can't be blank"
  end

  test "StudioChatMessage and CrdtBranch seed default project messages and Yjs delta branches" do
    messages = StudioChatMessage.default_messages_for("project_room")
    assert_operator messages.size, :>=, 2
    assert_includes messages.map(&:sender_name), "Aria (Mastering Eng)"
    assert_includes messages.map(&:sender_name), "Devon (Synth Lead)"

    branches = CrdtBranch.default_branches
    assert_operator branches.size, :>=, 2
    assert_includes branches.map(&:name), "main (master-bus-locked)"
    assert_includes branches.map(&:name), "alt-808-saturation-pass"
  end

  test "from_omniauth creates a new user, links existing email, and resolves username collisions" do
    existing_username_user = User.new(
      username: "oauth_producer",
      email: "taken_handle@saanskara.studio",
      password: "Password123!",
      password_confirmation: "Password123!"
    )
    existing_username_user.skip_confirmation!
    existing_username_user.save!

    auth = OmniAuth::AuthHash.new(
      provider: "google_oauth2",
      uid: "109876543210",
      info: {
        email: "oauth_producer@gmail.com",
        name: "OAuth Producer",
        image: "https://lh3.googleusercontent.com/a/default-user"
      }
    )

    user = User.from_omniauth(auth)
    assert user.persisted?
    assert_equal "google_oauth2", user.provider
    assert_equal "109876543210", user.uid
    assert_equal "oauth_producer@gmail.com", user.email
    assert_not_equal "oauth_producer", user.username
    assert_match(/\Aoauth_producer_/, user.username)
    assert_equal "OAuth Producer", user.display_name
    assert_equal "https://lh3.googleusercontent.com/a/default-user", user.avatar_url
    assert_not_nil user.confirmed_at

    # Subsequent login with same email links existing account
    email_user = User.new(
      username: "existing_studio_member",
      email: "member@saanskara.studio",
      password: "Password123!",
      password_confirmation: "Password123!"
    )
    email_user.skip_confirmation!
    email_user.save!

    link_auth = OmniAuth::AuthHash.new(
      provider: "google_oauth2",
      uid: "998877665544",
      info: {
        email: "member@saanskara.studio",
        name: "Studio Member",
        image: "https://lh3.googleusercontent.com/a/studio-member"
      }
    )

    linked = User.from_omniauth(link_auth)
    assert_equal email_user.id, linked.id
    assert_equal "google_oauth2", linked.provider
    assert_equal "998877665544", linked.uid
    assert_equal "https://lh3.googleusercontent.com/a/studio-member", linked.avatar_url
  end
end
