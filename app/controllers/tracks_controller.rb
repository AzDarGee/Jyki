# frozen_string_literal: true

class TracksController < ApplicationController
  before_action :set_project, only: [ :create ]
  before_action :set_track, only: [ :update, :destroy ]

  PALETTE = [ "#f59e0b", "#10b981", "#38bdf8", "#a855f7", "#ec4899", "#eab308", "#14b8a6", "#f97316" ].freeze

  def create
    next_pos = (@project.tracks.maximum(:position) || -1) + 1
    next_num = @project.tracks.count + 1
    raw_params = track_params

    track_type = raw_params[:track_type].presence || "audio"
    default_name = format("%02d • %s Track", next_num, track_type.capitalize)
    default_color = PALETTE[next_pos % PALETTE.size]
    default_deck = next_num <= 6 ? next_num : nil

    @track = @project.tracks.build(raw_params)
    @track.name = default_name if @track.name.blank?
    @track.position = next_pos if raw_params[:position].nil?
    @track.color_hex = default_color if raw_params[:color_hex].blank?
    @track.deck_number = default_deck if raw_params[:deck_number].nil? && default_deck && !@project.tracks.exists?(deck_number: default_deck)

    if @track.save
      payload = StudioBootstrapper.serialize_track(@track)
      respond_to do |format|
        format.json { render json: { ok: true, track: payload }, status: :created }
        format.turbo_stream { render json: { ok: true, track: payload }, status: :created }
      end
    else
      render json: { ok: false, errors: @track.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def update
    if @track.update(track_params)
      payload = StudioBootstrapper.serialize_track(@track)
      respond_to do |format|
        format.json { render json: { ok: true, track: payload } }
        format.turbo_stream { render json: { ok: true, track: payload } }
      end
    else
      render json: { ok: false, errors: @track.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    track_id = @track.id
    @track.destroy!

    respond_to do |format|
      format.json { render json: { ok: true, id: track_id } }
      format.turbo_stream { render json: { ok: true, id: track_id } }
    end
  end

  private

    def set_project
      @project = Project.find(params[:project_id])
    end

    def set_track
      @track = Track.includes(:project, track_clips: [ :audio_sample, :midi_clip ]).find(params[:id])
    end

    def track_params
      allowed = [
        :name,
        :track_type,
        :deck_number,
        :position,
        :color_hex,
        :volume_db,
        :pan,
        :muted,
        :soloed,
        :armed,
        :parent_bus_track_id
      ]

      if params[:track].present?
        params.expect(track: allowed)
      else
        params.permit(*allowed)
      end
    end
end
