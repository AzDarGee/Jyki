# frozen_string_literal: true

require "test_helper"

class WorkstationControllerTest < ActionDispatch::IntegrationTest
  self.fixture_table_names = []

  test "renders Jaku workstation SPA shell at root URL with all 5 zones" do
    get root_url
    assert_response :success

    # Root Turbo Frame for SPA URL cloaking
    assert_select "turbo-frame#jaku_workstation"

    # Zone A: Top Global Header Bar
    assert_select "[data-zone='header']", /@saanskara/
    assert_select "[data-zone='header'] button", /Create/
    assert_select "[data-zone='header'] button", /DJ/

    # Zone B: Master Meter / Global Spectrogram Strip
    assert_select "[data-zone='master-meter']", /LUFS/

    # Zone C: Primary Transport & Sub-Mode Toolbar
    assert_select "[data-zone='transport']", /BPM/
    assert_select "[data-zone='transport'] button", /Ideas/
    assert_select "[data-zone='transport'] button", /Song/
    assert_select "[data-zone='transport'] button", /Batch & Export/

    # Zone D: Main Center Workstation Area (Library, Track Headers, Timeline Canvas, Utility Rail)
    assert_select "[data-zone='sound-browser']", /Sound Libraries & Plugins/
    assert_select "[data-zone='track-headers']", /01\. Sub Bass 808/
    assert_select "[data-zone='timeline'] canvas[data-controller*='daw-timeline']"
    assert_select "[data-zone='utility-rail']"

    # Zone E: Bottom Mixer Console & Smooth Gain Automation Drawer
    assert_select "[data-zone='mixer-console']", /MIXER CONSOLE & SMOOTH GAIN AUTOMATION/
    assert_select "[data-zone='mixer-console']", /INSERTS/
  end

  test "appends a new track via turbo stream without redirecting URL" do
    post workstation_tracks_url, params: { track: { kind: "audio" } }, as: :turbo_stream
    assert_response :success
    assert_match(/turbo-stream/, response.media_type)
  end

  test "updates mixer state statelessly via turbo stream or json" do
    patch workstation_mixer_url, params: { mixer: { track_id: 1, gain_db: -3.5, pan: 10 } }, as: :json
    assert_response :success
  end
end

