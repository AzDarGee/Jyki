# frozen_string_literal: true

class User < ApplicationRecord
  STUDIO_PLAN_TIERS = {
    "studio_master_192_64" => "Studio Master (192kHz / 64-bit)",
    "producer_pro_96_32" => "Producer Pro (96kHz / 32-bit float)",
    "indie_creator_48_24" => "Indie Creator (48kHz / 24-bit)"
  }.freeze

  ROLES = [ "OWNER", "PRODUCER", "COLLABORATOR" ].freeze

  attr_accessor :login

  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable,
         :confirmable, :lockable, :timeoutable, :trackable,
         :omniauthable, stretches: 8

  normalizes :email, with: ->(e) { e.to_s.strip.downcase }
  normalizes :username, with: ->(u) { u.to_s.strip.downcase }

  validates :username, presence: true, uniqueness: { case_sensitive: false }, length: { minimum: 2, maximum: 40 }
  validates :studio_plan_tier, inclusion: { in: STUDIO_PLAN_TIERS.keys }
  validates :role, inclusion: { in: ROLES }

  before_validation :assign_studio_defaults, on: :create

  def self.find_for_database_authentication(warden_conditions)
    conditions = warden_conditions.dup
    login_value = conditions.delete(:login).to_s.strip.downcase
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

  private

    def assign_studio_defaults
      self.studio_plan_tier = "studio_master_192_64" if studio_plan_tier.blank?
      self.role = "OWNER" if role.blank?
    end
end
