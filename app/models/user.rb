# frozen_string_literal: true

class User < ApplicationRecord
  STUDIO_PLAN_TIERS = {
    "studio_master_192_64" => "Studio Master (192kHz / 64-bit)",
    "producer_pro_96_32" => "Producer Pro (96kHz / 32-bit float)",
    "indie_creator_48_24" => "Indie Creator (48kHz / 24-bit)"
  }.freeze

  STUDIO_PLANS = {
    "studio_master" => "Studio Master",
    "producer_pro" => "Producer Pro",
    "indie_creator" => "Indie Creator"
  }.freeze

  PROJECT_ROLES = {
    "owner" => "Owner (Full Admin)",
    "editor" => "Editor (Write Tracks & CRDT)",
    "collaborator" => "Collaborator (Stem & Mix)",
    "viewer" => "Viewer (Read-Only)"
  }.freeze

  ROLES = [ "OWNER", "EDITOR", "PRODUCER", "COLLABORATOR", "VIEWER" ].freeze

  attr_accessor :login

  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable,
         :confirmable, :lockable, :timeoutable, :trackable,
         :omniauthable, omniauth_providers: [ :google_oauth2 ], stretches: 8

  normalizes :email, with: ->(e) { e.to_s.strip.downcase }
  normalizes :username, with: ->(u) { u.to_s.strip.sub(/\A@/, "").downcase }

  validates :username, presence: true, uniqueness: { case_sensitive: false }, length: { minimum: 2, maximum: 40 }
  validates :studio_plan_tier, inclusion: { in: STUDIO_PLAN_TIERS.keys }
  validates :studio_plan, inclusion: { in: STUDIO_PLANS.keys }
  validates :project_role, inclusion: { in: PROJECT_ROLES.keys }
  validates :role, inclusion: { in: ROLES }

  before_validation :assign_studio_defaults

  def self.find_for_database_authentication(warden_conditions)
    conditions = warden_conditions.dup
    login_value = conditions.delete(:login).to_s.strip.sub(/\A@/, "").downcase
    if login_value.present?
      where(conditions.to_h).find_by("LOWER(username) = :val OR LOWER(email) = :val", val: login_value)
    elsif conditions.key?(:username) || conditions.key?(:email)
      where(conditions.to_h).first
    end
  end

  def initials
    handle = username.presence || email.to_s.split("@").first.presence || "GU"
    parts = handle.split(/[_\-. ]+/).reject(&:blank?)
    if parts.length >= 2
      "#{parts[0][0]}#{parts[1][0]}".upcase
    else
      handle.slice(0, 2).upcase
    end
  end

  def studio_plan_label
    STUDIO_PLAN_TIERS[studio_plan_tier] || STUDIO_PLAN_TIERS["studio_master_192_64"]
  end

  def studio_plan_short_label
    STUDIO_PLANS[studio_plan] || "Studio Master"
  end

  def project_role_label
    PROJECT_ROLES[project_role] || "Owner (Full Admin)"
  end

  def effective_permissions
    can_write_dsp = [ "owner", "editor", "collaborator" ].include?(project_role)
    can_manage_samples = [ "owner", "editor" ].include?(project_role)
    can_commit_crdt = [ "owner", "editor" ].include?(project_role)
    can_cloud_sync = [ "studio_master", "producer_pro" ].include?(studio_plan)
    can_lossless_export = [ "studio_master", "producer_pro" ].include?(studio_plan)
    can_manage_acl = project_role == "owner"

    [
      {
        label: "Track DSP, Mixer & Automation Write",
        granted: can_write_dsp,
        status: can_write_dsp ? "GRANTED" : "READ-ONLY"
      },
      {
        label: "Project Sample Library Upload & Delete",
        granted: can_manage_samples,
        status: can_manage_samples ? "GRANTED" : "RESTRICTED"
      },
      {
        label: "Yjs CRDT Branch Commit & Checkout",
        granted: can_commit_crdt,
        status: can_commit_crdt ? "GRANTED" : "READ-ONLY"
      },
      {
        label: "Firestore Cloud Project Sync",
        granted: can_cloud_sync,
        status: can_cloud_sync ? "GRANTED" : "LOCAL ONLY"
      },
      {
        label: "96kHz / 192kHz Lossless Stem Export",
        granted: can_lossless_export,
        status: can_lossless_export ? "GRANTED" : "48KHZ ONLY"
      },
      {
        label: "Project Collaborator ACL Management",
        granted: can_manage_acl,
        status: can_manage_acl ? "GRANTED" : "RESTRICTED"
      },
      {
        label: "Studio Project Room & DM Chat",
        granted: true,
        status: "GRANTED"
      }
    ]
  end

  def self.from_omniauth(auth)
    where(provider: auth.provider, uid: auth.uid).first_or_initialize.tap do |user|
      if user.new_record?
        user.email = auth.info.email
        base_handle = auth.info.email.to_s.split("@").first.to_s.gsub(/[^a-zA-Z0-9_]/, "_").downcase
        user.username = base_handle.presence || "producer_#{SecureRandom.hex(3)}"
        user.display_name = auth.info.name.presence || user.username.titleize
        user.password = Devise.friendly_token[0, 20]
        user.studio_plan_tier = "studio_master_192_64"
        user.studio_plan = "studio_master"
        user.project_role = "owner"
        user.role = "OWNER"
        user.skip_confirmation! if user.respond_to?(:skip_confirmation!)
        user.save
      end
    end
  end

  private

    def assign_studio_defaults
      self.studio_plan_tier = "studio_master_192_64" if studio_plan_tier.blank?
      self.studio_plan = "studio_master" if studio_plan.blank?
      self.project_role = "owner" if project_role.blank?
      self.role = project_role.to_s.upcase if role.blank? && ROLES.include?(project_role.to_s.upcase)
      self.role = "OWNER" if role.blank?
      self.display_name = "Saanskara" if display_name.blank?
      self.provider = "GOOGLE.COM" if provider.blank?
      self.storage_node_id = "4PS1G6fg..." if storage_node_id.blank?
    end
end
