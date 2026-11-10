# frozen_string_literal: true

# Default Studio Owner (@saanskara) & Project Collaborator ACL roster
saanskara = User.find_or_initialize_by(email: "saanskarastudios@gmail.com")
saanskara.assign_attributes(
  username: "saanskara",
  display_name: "Saanskara",
  password: "Password123!",
  password_confirmation: "Password123!",
  provider: "GOOGLE.COM",
  storage_node_id: "4PS1G6fg...",
  project_role: "owner",
  studio_plan: "studio_master",
  studio_plan_tier: "studio_master_192_64",
  role: "OWNER"
)
saanskara.skip_confirmation! if saanskara.respond_to?(:skip_confirmation!)
saanskara.save!

ProjectCollaborator.default_roster_for("proj_default")
StudioChatMessage.default_messages_for("project_room")
CrdtBranch.default_branches
