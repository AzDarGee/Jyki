# frozen_string_literal: true

class MidiClip < ApplicationRecord
  belongs_to :project, inverse_of: :midi_clips
  has_many :track_clips, dependent: :destroy, inverse_of: :midi_clip

  validates :name, presence: true
  validates :length_ticks, numericality: { only_integer: true, greater_than: 0 }
  validates :note_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  before_validation :ensure_uuid

  private

    def ensure_uuid
      self.uuid ||= SecureRandom.uuid
    end
end
