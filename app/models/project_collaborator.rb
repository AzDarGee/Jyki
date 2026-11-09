# frozen_string_literal: true

class ProjectCollaborator < ApplicationRecord
  ACL_ROLES = {
    "EDITOR" => "Editor (Write Tracks & CRDT)",
    "COLLABORATOR" => "Collaborator (Stem & Mix)",
    "VIEWER" => "Viewer (Read-Only)"
  }.freeze

  normalizes :username, with: ->(u) { u.to_s.strip.sub(/\A@/, "").downcase }
  normalizes :email, with: ->(e) { e.to_s.strip.downcase }

  validates :project_slug, presence: true
  validates :username, presence: true, uniqueness: { scope: :project_slug, case_sensitive: false }
  validates :role, inclusion: { in: ACL_ROLES.keys }

  before_validation :ensure_collaborator_metadata

  def self.default_roster_for(project_slug = "proj_default")
    existing = where(project_slug: project_slug).order(:id).to_a
    return existing if existing.any?

    [
      create!(
        project_slug: project_slug,
        username: "aria_mastering",
        external_user_id: "usr_aria_mastering",
        email: "aria@saanskara.studio",
        role: "EDITOR",
        added_at_label: "Added 17:00 UTC"
      ),
      create!(
        project_slug: project_slug,
        username: "devon_synth",
        external_user_id: "usr_devon_synth",
        email: "devon@saanskara.studio",
        role: "COLLABORATOR",
        added_at_label: "Added 17:05 UTC"
      )
    ]
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
    where(project_slug: project_slug).order(:id).to_a
  end

  private

    def ensure_collaborator_metadata
      self.project_slug = "proj_default" if project_slug.blank?
      self.role = role.to_s.upcase.presence || "EDITOR"
      self.role = "EDITOR" unless ACL_ROLES.key?(self.role)
      self.external_user_id = "usr_#{username}" if external_user_id.blank? && username.present?
      self.email = "#{username}@saanskara.studio" if email.blank? && username.present?
      self.added_at_label = "Added #{Time.current.utc.strftime('%H:%M')} UTC" if added_at_label.blank?
    end
end

