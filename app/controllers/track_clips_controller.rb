# frozen_string_literal: true

class TrackClipsController < ApplicationController
  before_action :set_track, only: [ :create ]
  before_action :set_track_clip, only: [ :update, :destroy ]

  def create
    raw_params = track_clip_params.to_h.symbolize_keys
    inferred_kind = raw_params[:clip_kind].presence || (@track.midi? || @track.instrument? ? "midi" : "audio")
    raw_params[:clip_kind] = inferred_kind

    if inferred_kind == "midi"
      raw_params[:audio_sample_id] = nil
      if raw_params[:midi_clip_id].blank?
        _, midi_clip = StudioBootstrapper.ensure_default_clip_source_for!(@track, "midi")
        raw_params[:midi_clip_id] = midi_clip.id
      end
    else
      raw_params[:midi_clip_id] = nil
      if raw_params[:audio_sample_id].blank?
        audio_sample, = StudioBootstrapper.ensure_default_clip_source_for!(@track, "audio")
        raw_params[:audio_sample_id] = audio_sample.id
      end
    end

    raw_params[:start_tick] = (raw_params[:start_tick] || 0).to_i
    raw_params[:duration_ticks] = (raw_params[:duration_ticks].presence || 3840).to_i
    raw_params[:color_hex] ||= @track.color_hex
    bar_num = (raw_params[:start_tick] / 3840) + 1
    raw_params[:name] = "#{@track.name.sub(/^\d+\s*•\s*/, '')} • Bar #{bar_num}" if raw_params[:name].blank?

    @track_clip = @track.track_clips.build(raw_params.merge(project: @track.project))

    if @track_clip.save
      payload = StudioBootstrapper.serialize_track_clip(@track_clip)
      respond_to do |format|
        format.json { render json: { ok: true, track_clip: payload }, status: :created }
        format.turbo_stream { render json: { ok: true, track_clip: payload }, status: :created }
      end
    else
      render json: { ok: false, errors: @track_clip.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def update
    if @track_clip.update(track_clip_params)
      payload = StudioBootstrapper.serialize_track_clip(@track_clip.reload)
      respond_to do |format|
        format.json { render json: { ok: true, track_clip: payload } }
        format.turbo_stream { render json: { ok: true, track_clip: payload } }
      end
    else
      render json: { ok: false, errors: @track_clip.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    clip_id = @track_clip.id
    @track_clip.destroy!

    respond_to do |format|
      format.json { render json: { ok: true, id: clip_id } }
      format.turbo_stream { render json: { ok: true, id: clip_id } }
    end
  end

  private

    def set_track
      @track = Track.includes(:project).find(params[:track_id])
    end

    def set_track_clip
      @track_clip = TrackClip.includes(:project, :track, :audio_sample, :midi_clip).find(params[:id])
    end

    def track_clip_params
      allowed = [
        :track_id,
        :clip_kind,
        :audio_sample_id,
        :midi_clip_id,
        :name,
        :color_hex,
        :scene_slot_index,
        :start_tick,
        :duration_ticks,
        :source_offset_ticks,
        :source_start_frame,
        :source_end_frame,
        :loop_enabled,
        :loop_start_tick,
        :loop_end_tick,
        :gain_db,
        :transpose_semitones,
        :detune_cents,
        :warp_enabled,
        :warp_algorithm,
        :time_stretch_ratio,
        :fade_in_ticks,
        :fade_out_ticks,
        :fade_curve,
        :muted
      ]

      if params[:track_clip].present?
        params.expect(track_clip: allowed)
      else
        params.permit(*allowed)
      end
    end
end
