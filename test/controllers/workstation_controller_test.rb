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
    assert_select "[data-zone='header'] #top_bar_auth_badge"
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

  test "renders 6-deck Phase-Locked Parallel Beatgrid DJ workspace in #jaku_stage_body" do
    get root_url
    assert_response :success

    assert_select "#jaku_stage_body"
    assert_select "[data-controller='dj-beatgrid'] [data-zone='dj-beatgrid']", /PHASE-LOCKED PARALLEL BEATGRID · MASTER A · 128\.00 BPM/
    assert_select "[data-zone='dj-beatgrid'] button", /QUANTIZE ON/
    assert_select "[data-zone='dj-beatgrid'] button", /Beatmatch Sync All to Master/
    assert_select "[data-zone='dj-beatgrid'] canvas[data-dj-beatgrid-target='canvas']"
    assert_select "[data-zone='dj-beatgrid']", /PHASE LOCKED/
    assert_select "[data-zone='dj-beatgrid']", /OUT OF PHASE/

    # All 6 decks rendered from @decks collection via _dj_deck.html.erb
    assert_select "[data-controller='dj-deck']", count: 6
    assert_select "[data-deck-letter='A']", /Saanskara Dubplate \(VIP Mix\)/
    assert_select "[data-deck-letter='B']", /Obsidian Warehouse Tool/
    assert_select "[data-deck-letter='C']", /Granular Fog Loop/
    assert_select "[data-deck-letter='D']", /Neon Drift \(Peak Hour\)/
    assert_select "[data-deck-letter='E']", /Rust Belt Percussion/
    assert_select "[data-deck-letter='F']", /Halftime Sub Ritual/
  end

  test "renders top-right Sign In pill and Studio Auth slide-over drawer when signed out" do
    get root_url
    assert_response :success

    assert_select "#top_bar_auth_badge button", /Sign In/
    assert_select "#studio_auth_drawer", /Studio Auth/
    assert_select "#studio_auth_drawer", /Identity · Project Authorization Matrix/
    assert_select "#studio_auth_drawer", /Not Signed In/
    assert_select "#studio_auth_drawer button", /Sign Up \(New Producer\)/
    assert_select "#studio_auth_drawer button", /Sign In \(Existing\)/
    assert_select "#studio_auth_drawer", /Sign Up with Google/
    assert_select "#studio_auth_drawer", /OR WITH EMAIL & USERNAME/
    assert_select "#studio_auth_drawer", /Studio Master \(192kHz \/ 64-bit\)/
    assert_select "#studio_auth_drawer button[type='submit']", /Sign Up with Email & Username/
  end

  test "registers a new producer via Devise turbo stream without redirecting URL" do
    post user_registration_url, params: {
      user: {
        username: "ashish_darji",
        email: "ashdarji1@gmail.com",
        password: "Password123!",
        password_confirmation: "Password123!",
        studio_plan_tier: "studio_master_192_64"
      }
    }, as: :turbo_stream

    assert_response :success
    assert_match(/turbo-stream/, response.media_type)
    assert_match(/@ashish_darji/, response.body)
    assert_match(/OWNER/, response.body)
  end

  test "renders inline validation errors on invalid registration without redirecting" do
    post user_registration_url, params: {
      user: {
        username: "",
        email: "invalid",
        password: "short",
        password_confirmation: "mismatch"
      }
    }, as: :turbo_stream

    assert_response :unprocessable_content
    assert_match(/studio_auth_frame/, response.body)
  end

  test "signs in via username or email and signs out via Devise turbo stream without redirecting" do
    user = User.new(
      username: "saanskara_lead",
      email: "lead@saanskara.studio",
      password: "Password123!",
      password_confirmation: "Password123!",
      studio_plan_tier: "studio_master_192_64",
      role: "OWNER"
    )
    user.skip_confirmation! if user.respond_to?(:skip_confirmation!)
    user.save!

    post user_session_url, params: {
      user: {
        login: "saanskara_lead",
        password: "Password123!"
      }
    }, as: :turbo_stream

    assert_response :success
    assert_match(/turbo-stream/, response.media_type)
    assert_match(/@saanskara_lead/, response.body)

    delete destroy_user_session_url, as: :turbo_stream
    assert_response :success
    assert_match(/Sign In/, response.body)
  end
end
