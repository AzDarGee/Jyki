# frozen_string_literal: true

require "test_helper"

class HomeControllerTest < ActionDispatch::IntegrationTest
  self.fixture_table_names = []

  test "HomeController#index auto-bootstraps default project, 6 tracks, clips, and 6-deck DJ view" do
    Project.destroy_all
    assert_equal 0, Project.count

    get home_url
    assert_response :success

    assert_equal 1, Project.count
    project = Project.first
    assert_equal "Saanskara Raga Session 01", project.name
    assert_equal 124.0, project.bpm.to_f
    assert_equal 960, project.ppqn
    assert_equal 6, project.tracks.count
    assert_operator project.track_clips.count, :>=, 10
    assert_operator project.automation_lanes.count, :>=, 1

    assert_select "#saanskara-daw[data-controller='studio'][data-theme='midnight'][data-studio-project-value]"
    assert_select "#saanskara-daw .daw-transport-bar", /Saanskara Studio DAW/
    assert_select "#saanskara-daw [data-studio-target='trackList'] .track-row", count: 6
    assert_select "#saanskara-daw #dj-6deck-panel .dj-deck-card", count: 6
    assert_select "#saanskara-daw canvas#waveform-canvas[data-studio-target='timelineCanvas']"
    assert_select "#saanskara-daw script", count: 0
  end

  test "ProjectsController#update persists bpm, workspace_mode, theme_name, and scale_name" do
    project = StudioBootstrapper.ensure_default_project!

    patch project_url(project), params: {
      project: {
        bpm: 132.5,
        workspace_mode: "dj_6deck",
        theme_name: "saffron",
        scale_name: "yaman",
        master_volume_db: -1.5
      }
    }, as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal true, body["ok"]
    assert_equal 132.5, body.dig("project", "bpm")
    assert_equal "dj_6deck", body.dig("project", "workspace_mode")
    assert_equal "saffron", body.dig("project", "theme_name")

    project.reload
    assert_in_delta 132.5, project.bpm.to_f, 0.01
    assert_equal "dj_6deck", project.workspace_mode
    assert_equal "saffron", project.theme_name
    assert_equal "yaman", project.scale_name
  end

  test "TracksController creates, updates mute/solo/arm/volume/pan, and deletes tracks" do
    project = StudioBootstrapper.ensure_default_project!
    track = project.tracks.first

    patch track_url(track), params: {
      track: {
        muted: true,
        soloed: true,
        armed: false,
        volume_db: -4.5,
        pan: 0.35
      }
    }, as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal true, body["ok"]
    assert_equal true, body.dig("track", "muted")
    assert_equal true, body.dig("track", "soloed")
    assert_equal false, body.dig("track", "armed")
    assert_in_delta(-4.5, body.dig("track", "volume_db"), 0.01)

    track.reload
    assert track.muted?
    assert track.soloed?
    assert_not track.armed?
    assert_in_delta(-4.5, track.volume_db, 0.01)
    assert_in_delta(0.35, track.pan, 0.01)

    assert_difference -> { project.tracks.count }, 1 do
      post project_tracks_url(project), params: {
        track: { track_type: "midi", name: "07 • Bansuri Flute" }
      }, as: :json
    end
    assert_response :created
    created_id = JSON.parse(response.body).dig("track", "id")

    assert_difference -> { project.tracks.count }, -1 do
      delete track_url(created_id), as: :json
    end
    assert_response :success
  end

  test "TrackClipsController creates clips on audio/midi tracks and updates timeline start_tick and duration_ticks" do
    project = StudioBootstrapper.ensure_default_project!
    audio_track = project.tracks.find_by!(track_type: "audio")
    midi_track = project.tracks.find_by!(track_type: "midi")

    assert_difference -> { audio_track.track_clips.count }, 1 do
      post track_track_clips_url(audio_track), params: {
        track_clip: {
          start_tick: 11520,
          duration_ticks: 3840
        }
      }, as: :json
    end
    assert_response :created
    audio_clip_payload = JSON.parse(response.body)["track_clip"]
    assert_equal "audio", audio_clip_payload["clip_kind"]
    assert_equal 11520, audio_clip_payload["start_tick"]

    assert_difference -> { midi_track.track_clips.count }, 1 do
      post track_track_clips_url(midi_track), params: {
        track_clip: {
          start_tick: 19200,
          duration_ticks: 3840
        }
      }, as: :json
    end
    assert_response :created
    midi_clip_payload = JSON.parse(response.body)["track_clip"]
    assert_equal "midi", midi_clip_payload["clip_kind"]
    assert_operator midi_clip_payload["midi_events"].size, :>=, 1

    clip_id = midi_clip_payload["id"]
    patch track_clip_url(clip_id), params: {
      track_clip: {
        start_tick: 23040,
        duration_ticks: 7680,
        loop_enabled: true
      }
    }, as: :json

    assert_response :success
    updated_payload = JSON.parse(response.body)["track_clip"]
    assert_equal 23040, updated_payload["start_tick"]
    assert_equal 7680, updated_payload["duration_ticks"]
    assert_equal true, updated_payload["loop_enabled"]
  end
end
