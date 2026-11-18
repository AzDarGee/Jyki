# frozen_string_literal: true

class AutomationLane < ApplicationRecord
  belongs_to :project, inverse_of: :automation_lanes
  belongs_to :track, optional: true, inverse_of: :automation_lanes
  belongs_to :track_clip, optional: true, inverse_of: :automation_lanes

  validates :parameter_path, presence: true
  validates :min_value, numericality: true
  validates :max_value, numericality: true
  validate :max_value_not_less_than_min_value

  before_validation :assign_defaults

  private

    def assign_defaults
      self.uuid ||= SecureRandom.uuid
      self.project ||= track&.project || track_clip&.project
    end

    def max_value_not_less_than_min_value
      return if min_value.nil? || max_value.nil?

      errors.add(:max_value, "must be greater than or equal to min_value") if max_value < min_value
    end
end
