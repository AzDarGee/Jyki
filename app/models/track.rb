# frozen_string_literal: true

class Track < ApplicationRecord
  belongs_to :project, inverse_of: :tracks
  belongs_to :parent_bus_track, class_name: "Track", optional: true, inverse_of: :child_tracks

  has_many :child_tracks,
           class_name: "Track",
           foreign_key: :parent_bus_track_id,
           dependent: :nullify,
           inverse_of: :parent_bus_track
  has_many :track_clips, -> { order(:start_tick, :id) }, dependent: :destroy, inverse_of: :track
  has_many :automation_lanes, dependent: :destroy, inverse_of: :track

  enum :track_type, {
    audio: "audio",
    midi: "midi",
    instrument: "instrument",
    stem: "stem",
    bus: "bus",
    return: "return",
    master: "master",
    dj_deck: "dj_deck"
  }, default: :audio, validate: true

  validates :name, presence: true
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :deck_number, inclusion: { in: 1..6 }, allow_nil: true
  validates :pan, numericality: { greater_than_or_equal_to: -1.0, less_than_or_equal_to: 1.0 }

  before_validation :ensure_uuid

  private

    def ensure_uuid
      self.uuid ||= SecureRandom.uuid
    end
end
