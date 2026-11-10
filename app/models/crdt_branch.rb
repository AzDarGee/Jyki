# frozen_string_literal: true

class CrdtBranch < ApplicationRecord
  validates :name, presence: true, length: { maximum: 120 }
  validates :delta_vector, presence: true

  before_validation :ensure_branch_defaults

  def self.default_branches
    existing = order(:id).to_a
    return existing if existing.any?

    [
      create!(
        name: "main (master-bus-locked)",
        delta_vector: "AQT/AQABc2FhbnNreXJkdW1Rhdw==",
        committed_at_label: "17:00 UTC"
      ),
      create!(
        name: "alt-808-saturation-pass",
        delta_vector: "AQf/AgB4808tZzxpZGUtcmFtCA==",
        committed_at_label: "17:12 UTC"
      )
    ]
  rescue ActiveRecord::RecordInvalid
    order(:id).to_a
  end

  private

    def ensure_branch_defaults
      if delta_vector.blank?
        slug = name.to_s.parameterize.presence || "snapshot"
        encoded = Base64.strict_encode64("yjs:#{slug}:#{Time.current.to_i}")[0, 22]
        self.delta_vector = "AQt/#{encoded}=="
      end
      self.committed_at_label = "#{Time.current.utc.strftime('%H:%M')} UTC" if committed_at_label.blank?
    end
end

