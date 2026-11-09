# frozen_string_literal: true

require "test_helper"

class UserTest < ActiveSupport::TestCase
  self.fixture_table_names = []

  test "sets default studio_plan_tier and role and validates username" do
    user = User.new(
      username: "ashish_darji",
      email: "ashdarji1@gmail.com",
      password: "Password123!",
      password_confirmation: "Password123!"
    )
    assert user.valid?
    assert_equal "studio_master_192_64", user.studio_plan_tier
    assert_equal "OWNER", user.role
    assert_equal "AD", user.initials
    assert_equal "Studio Master (192kHz / 64-bit)", user.studio_plan_label
  end

  test "requires unique username and email" do
    user = User.new(username: "", email: "", password: "Password123!")
    assert_not user.valid?
    assert_includes user.errors[:username], "can't be blank"
    assert_includes user.errors[:email], "can't be blank"
  end
end
