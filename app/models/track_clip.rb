# frozen_string_literal: true

class TrackClip < ApplicationRecord
  belongs_to :project, inverse_of: :track_clips
  belongs_to :track, inverse_of: :track_clips
  belongs_to :audio_sample, optional: true, inverse_of: :track_clips
  belongs_to :midi_clip, optional: true, inverse_of: :track_clips

  has_many :automation_lanes, dependent: :destroy, inverse_of: :track_clip

  alias_attribute :offset_ticks, :source_offset_ticks
  alias_attribute :pitch_cents, :detune_cents
  alias_attribute :trim_start_frame, :source_start_frame
  alias_attribute :trim_end_frame, :source_end_frame

  enum :clip_kind, {
    audio: "audio",
    midi: "midi"
  }, validate: true

  enum :warp_algorithm, {
    beats: "beats",
    tones: "tones",
    complex: "complex",
    repitch: "repitch"
  }, default: :complex, prefix: :warp, validate: { allow_nil: true }

  scope :in_tick_range, ->(start_tick, end_tick) {
    s_tick = start_tick.to_i
    e_tick = end_tick.to_i
    if e_tick > s_tick
      where("track_clips.start_tick < ? AND (track_clips.start_tick + track_clips.duration_ticks) > ?", e_tick, s_tick)
    else
      where("track_clips.start_tick <= ? AND (track_clips.start_tick + track_clips.duration_ticks) >= ?", e_tick, s_tick)
    end
  }

  validates :clip_kind, presence: true
  validates :start_tick, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :duration_ticks, numericality: { only_integer: true, greater_than: 0 }
  validates :source_offset_ticks, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :source_start_frame, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :time_stretch_ratio, numericality: { greater_than: 0 }
  validates :fade_in_ticks, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :fade_out_ticks, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :fade_curve, numericality: { greater_than_or_equal_to: -1.0, less_than_or_equal_to: 1.0 }
  validate :source_matches_clip_kind

  before_validation :assign_defaults

  def end_tick
    start_tick.to_i + duration_ticks.to_i
  end

  private

    def assign_defaults
      self.uuid ||= SecureRandom.uuid
      self.project ||= track&.project || audio_sample&.project || midi_clip&.project
    end

    def source_matches_clip_kind
      case clip_kind
      when "audio"
        errors.add(:audio_sample, "must be present for audio clips") if audio_sample_id.blank? && audio_sample.blank?
        errors.add(:midi_clip, "must be blank for audio clips") if midi_clip_id.present? || midi_clip.present?
      when "midi"
        errors.add(:midi_clip, "must be present for midi clips") if midi_clip_id.blank? && midi_clip.blank?
        errors.add(:audio_sample, "must be blank for midi clips") if audio_sample_id.present? || audio_sample.present?
      end
    end
end
