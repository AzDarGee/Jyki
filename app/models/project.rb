# frozen_string_literal: true

class Project < ApplicationRecord
  belongs_to :user, optional: true, inverse_of: :projects
  belongs_to :crdt_branch, optional: true, inverse_of: :projects

  has_many :automation_lanes, dependent: :destroy, inverse_of: :project
  has_many :track_clips, dependent: :destroy, inverse_of: :project
  has_many :midi_clips, dependent: :destroy, inverse_of: :project
  has_many :tracks, -> { order(:position, :id) }, dependent: :destroy, inverse_of: :project
  has_many :audio_samples, dependent: :nullify, inverse_of: :project

  enum :workspace_mode, {
    daw: "daw",
    dj_6deck: "dj_6deck",
    hybrid: "hybrid"
  }, default: :daw, validate: true

  validates :name, presence: true
  validates :bpm, numericality: { greater_than: 0 }
  validates :ppqn, numericality: { only_integer: true, greater_than: 0 }
  validates :sample_rate, numericality: { only_integer: true, greater_than: 0 }
  validates :time_signature_numerator, numericality: { only_integer: true, greater_than: 0 }
  validates :time_signature_denominator, numericality: { only_integer: true, greater_than: 0 }
  validates :root_note, numericality: { only_integer: true, in: 0..127 }, allow_nil: true
  validates :theme_name, presence: true

  before_validation :ensure_project_identifiers

  def ticks_to_seconds(ticks)
    return 0.0 if bpm.to_f <= 0.0 || ppqn.to_i <= 0

    (ticks.to_f * 60.0) / (bpm.to_f * ppqn.to_f)
  end

  def seconds_to_ticks(seconds)
    return 0 if bpm.to_f <= 0.0 || ppqn.to_i <= 0

    ((seconds.to_f * bpm.to_f * ppqn.to_f) / 60.0).round
  end

  def ticks_to_frames(ticks)
    (ticks_to_seconds(ticks) * sample_rate.to_f).round
  end

  def frames_to_ticks(frames)
    return 0 if sample_rate.to_i <= 0

    seconds_to_ticks(frames.to_f / sample_rate.to_f)
  end

  private

    def ensure_project_identifiers
      self.uuid ||= SecureRandom.uuid
      if slug.blank? && name.present?
        base = name.to_s.parameterize.presence || "project"
        self.slug = "#{base}-#{uuid.split('-').first}"
      end
    end
end
