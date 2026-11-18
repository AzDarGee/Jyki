# frozen_string_literal: true

class AudioSample < ApplicationRecord
  belongs_to :project, optional: true, inverse_of: :audio_samples
  has_many :track_clips, dependent: :restrict_with_error, inverse_of: :audio_sample

  validates :name, presence: true
  validates :sample_rate, numericality: { only_integer: true, greater_than: 0 }
  validates :channels, numericality: { only_integer: true, greater_than: 0 }
  validates :bit_depth, numericality: { only_integer: true, greater_than: 0 }
  validates :total_frames, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :duration_ms, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :detected_bpm, numericality: { greater_than: 0 }, allow_nil: true

  before_validation :ensure_uuid

  private

    def ensure_uuid
      self.uuid ||= SecureRandom.uuid
    end
end
