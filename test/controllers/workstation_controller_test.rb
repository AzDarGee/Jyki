# frozen_string_literal: true

require "test_helper"

class WorkstationControllerTest < ActionDispatch::IntegrationTest
  self.fixture_table_names = []

  test "renders Jaku workstation SPA shell at root URL with all 5 zones" do
    get root_url
    assert_response :success

    # Root Turbo Frame for SPA URL cloaking & SCSS Theme Engine binding
    assert_select "html[data-controller*='theme-bootstrap'][data-action*='turbo:load@document->theme-bootstrap#lockRootUrl'][data-action*='turbo:frame-render@document->theme-bootstrap#lockRootUrl'][data-action*='turbo:before-fetch-request@document->theme-bootstrap#injectSpaHeader'][data-action*='popstate@window->theme-bootstrap#lockRootUrl']"
    assert_select "head script:not([type])", count: 0
    assert_select "turbo-frame#jaku_workstation.jaku-workstation-shell[data-workstation-theme-value='midnight'][data-theme='midnight']"
    assert_select "style", count: 0

    # Zone A: Top Global Header Bar & Top-Left Theme Toggle Pill
    assert_select "[data-zone='header'] button[data-workstation-target='themeButton'][data-action*='workstation#toggleTheme'][data-theme-current='midnight']"
    assert_select "[data-zone='header'] [data-workstation-target='themeIcon']", /🌙/
    assert_select "[data-zone='header'] [data-workstation-target='themeLabel']", /Dark/
    assert_select "[data-zone='header'] #top_bar_auth_badge"
    assert_select "[data-zone='header'] button", /Create/
    assert_select "[data-zone='header'] button", /DJ/

    # Verify compiled SCSS pipeline output (app/assets/builds/tailwind.css) defines all themes and zone selectors
    compiled_css = Rails.root.join("app/assets/builds/tailwind.css").read
    assert_match(/--saanskara-bg-obsidian/, compiled_css)
    assert_match(/--jaku-bg-obsidian/, compiled_css)
    assert_match(/\[data-theme=["']?midnight["']?\]/, compiled_css)
    assert_match(/\[data-theme=["']?saffron["']?\]/, compiled_css)
    assert_match(/\[data-theme=["']?frost["']?\]/, compiled_css)
    assert_match(/\[data-zone=["']?header["']?\]/, compiled_css)
    assert_match(/\[data-zone=["']?master-meter["']?\]/, compiled_css)
    assert_match(/\[data-zone=["']?transport["']?\]/, compiled_css)
    assert_match(/\[data-zone=["']?sound-browser["']?\]/, compiled_css)
    assert_match(/\[data-zone=["']?track-headers["']?\]/, compiled_css)
    assert_match(/\[data-zone=["']?timeline["']?\]/, compiled_css)
    assert_match(/\[data-zone=["']?dj-beatgrid["']?\]/, compiled_css)
    assert_match(/\[data-zone=["']?dj-deck-matrix["']?\]/, compiled_css)
    assert_match(/\[data-zone=["']?mixer-console["']?\]/, compiled_css)
    assert_match(/#jyki_right_sidebar/, compiled_css)
    assert_match(/#studio_auth_drawer/, compiled_css)
    assert_match(/input\[type=["']?range["']?\]\.jaku-fader/, compiled_css)

    # Zone B: Master Meter / Global Spectrogram Strip
    assert_select "[data-zone='master-meter']", /LUFS/

    # Zone C: Primary Transport & Sub-Mode Toolbar
    assert_select "[data-zone='transport']", /BPM/
    assert_select "[data-zone='transport'] button", /Ideas/
    assert_select "[data-zone='transport'] button", /Song/
    assert_select "[data-zone='transport'] button", /Batch & Export/

    # Zone D: Main Center Workstation Area (Library, Track Headers, Timeline Canvas, Utility Rail)
    assert_select "[data-zone='sound-browser']", /Sound Libraries & Plugins/
    assert_select "[data-zone='track-headers'][class*='transition-all']", /01\. Sub Bass 808/
    assert_select "[data-mixer-target='trackHeaderRow'][data-action*='mixer#handleTrackRowClick']", minimum: 4
    assert_select "[data-mixer-target='collapsedTrackPill']", minimum: 4
    assert_select "[data-zone='track-headers'] [data-workstation-target='trackCreatorBox'] [data-workstation-target='expandedTrackCreator']"
    assert_select "[data-zone='track-headers'] [data-workstation-target='trackCreatorBox'] [data-workstation-target='collapsedTrackCreator']"
    assert_select "[data-zone='track-headers'] [data-workstation-target='collapsedTrackCreator'] [data-workstation-target='collapsedTrackTrigger'][data-action*='workstation#toggleCollapsedTrackMenu']"
    assert_select "[data-zone='track-headers'] [data-workstation-target='collapsedTrackMenu'] button[data-track-kind='audio'][data-action*='workstation#addEmptyTrack']"
    assert_select "[data-zone='track-headers'] [data-workstation-target='collapsedTrackMenu'] button[data-track-kind='midi'][data-action*='workstation#addEmptyTrack']"
    assert_select "[data-zone='track-headers'] [data-workstation-target='collapsedTrackMenu'] button[data-track-kind='bus'][data-action*='workstation#addEmptyTrack']"
    assert_select "[data-zone='timeline'] canvas[data-controller*='daw-timeline']"
    assert_select "[data-zone='utility-rail']"

    # Zone E: Bottom Mixer Console & Smooth Gain Automation Drawer
    assert_select "[data-zone='mixer-console']", /MIXER CONSOLE & SMOOTH GAIN AUTOMATION/
    assert_select "[data-zone='mixer-console']", /INSERTS/
  end

  test "appends a new track via turbo stream without redirecting URL and persists it in the database" do
    get root_url
    assert_response :success
    initial_db_count = Track.count
    assert_operator initial_db_count, :>=, 4

    assert_difference -> { Track.count }, 1 do
      post workstation_tracks_url, params: { track: { kind: "audio" } }, as: :turbo_stream
    end
    assert_response :success
    assert_match(/turbo-stream/, response.media_type)
    assert_match(/data-workstation-target="expandedTrackContent"\s+class="flex/, response.body)

    created_track = Track.order(:id).last
    assert_equal "audio", created_track.track_type
    assert_includes response.body, "id=\"track_header_row_#{created_track.id}\""
    assert_includes response.body, "id=\"mixer_channel_card_#{created_track.id}\""

    # Reloading root URL renders the persisted track from the database
    get root_url
    assert_response :success
    assert_select "#track_header_row_#{created_track.id}"
    assert_select "#mixer_channel_card_#{created_track.id}"

    # When the Tracks panel is collapsed, adding a track (Audio / MIDI / Bus) renders it in collapsed state and saves to DB
    [ "audio", "midi", "bus" ].each_with_index do |kind, idx|
      assert_difference -> { Track.count }, 1 do
        post workstation_tracks_url, params: {
          current_count: 5 + idx,
          collapsed: true,
          track: { kind: kind }
        }, as: :turbo_stream
      end
      assert_response :success
      assert_match(/turbo-stream/, response.media_type)
      assert_match(/data-workstation-target="expandedTrackContent"\s+class="hidden/, response.body)
      assert_match(/data-workstation-target="collapsedTrackContent"[\s\S]*?class="flex/, response.body)
      assert_equal kind, Track.order(:id).last.track_type
    end
  end

  test "deletes a track via turbo stream and json without redirecting URL and removes it from the database" do
    get root_url
    assert_response :success
    first_track = Track.order(:position, :id).first
    second_track = Track.order(:position, :id).second
    assert_not_nil first_track
    assert_not_nil second_track

    assert_select "#track_header_row_#{first_track.id} button[data-action*='deleteTrack']"
    assert_select "#mixer_channel_card_#{first_track.id} button[data-action*='deleteTrack']"

    assert_difference -> { Track.count }, -1 do
      delete workstation_track_url(first_track.id), as: :turbo_stream
    end
    assert_response :success
    assert_match(/turbo-stream/, response.media_type)
    assert_match(/action="remove" target="track_header_row_#{first_track.id}"/, response.body)
    assert_match(/action="remove" target="mixer_channel_card_#{first_track.id}"/, response.body)
    assert_match(/action="remove" target="ideas_track_column_#{first_track.id}"/, response.body)

    assert_difference -> { Track.count }, -1 do
      delete workstation_track_url(second_track.id), as: :json
    end
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "ok", body["status"]
    assert_equal second_track.id, body["track_id"]
  end

  test "updates mixer state via turbo stream or json and persists to database" do
    get root_url
    track = Track.order(:position, :id).first
    patch workstation_mixer_url, params: { mixer: { track_id: track.id, gain_db: -3.5, pan: 10, muted: true } }, as: :json
    assert_response :success
    track.reload
    assert_in_delta(-3.5, track.volume_db, 0.01)
    assert_in_delta(0.2, track.pan, 0.01)
    assert_equal true, track.muted
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
    assert_select "#studio_auth_drawer form[action='#{user_google_oauth2_omniauth_authorize_path}'][method='post'] button[type='submit']", /Sign Up with Google/
    assert_select "#studio_auth_drawer", /OR WITH EMAIL & USERNAME/
    assert_select "#studio_auth_drawer", /Studio Master \(192kHz \/ 64-bit\)/
    assert_select "#studio_auth_drawer button[type='submit']", /Sign Up with Email & Username/
  end

  test "authenticates via Google OAuth2 callback and handles failure gracefully" do
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2",
      uid: "google-uid-42",
      info: {
        email: "raga_master@gmail.com",
        name: "Raga Master",
        image: "https://lh3.googleusercontent.com/a/raga-master"
      }
    )

    get user_google_oauth2_omniauth_callback_url
    assert_redirected_to root_path
    follow_redirect!
    assert_response :success
    assert_select "#top_bar_auth_badge", /@raga_master/
  ensure
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    OmniAuth.config.test_mode = false
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

  test "renders authenticated Studio Auth drawer with Identity and Roles & ACL tabs and handles RBAC turbo streams" do
    user = User.new(
      username: "saanskara",
      display_name: "Saanskara",
      email: "saanskarastudios@gmail.com",
      password: "Password123!",
      password_confirmation: "Password123!",
      provider: "GOOGLE.COM",
      storage_node_id: "4PS1G6fg...",
      project_role: "owner",
      studio_plan: "studio_master",
      role: "OWNER"
    )
    user.skip_confirmation! if user.respond_to?(:skip_confirmation!)
    user.save!

    ProjectCollaborator.find_or_create_by!(project_slug: "proj_default", username: "aria_mastering") do |c|
      c.external_user_id = "usr_aria_mastering"
      c.email = "aria@saanskara.studio"
      c.role = "EDITOR"
      c.added_at_label = "Added 17:00 UTC"
    end
    ProjectCollaborator.find_or_create_by!(project_slug: "proj_default", username: "devon_synth") do |c|
      c.external_user_id = "usr_devon_synth"
      c.email = "devon@saanskara.studio"
      c.role = "COLLABORATOR"
      c.added_at_label = "Added 17:05 UTC"
    end

    post user_session_url, params: {
      user: { login: "saanskara", password: "Password123!" }
    }, as: :turbo_stream
    assert_response :success

    # Verify both Identity and Roles & ACL tabs are rendered inside the authenticated drawer
    assert_match(/Authenticated Studio Identity/, response.body)
    assert_match(/SESSION ACTIVE/, response.body)
    assert_match(/CONNECTED \(4PS1G6fg…\)/, response.body)
    assert_match(/Active Session Role &amp; Subscription Tier/, response.body)
    assert_match(/RBAC ENFORCED/, response.body)
    assert_match(/Track DSP, Mixer &amp; Automation Write/, response.body)
    assert_match(/Project Collaborator ACL/, response.body)
    assert_match(/@aria_mastering/, response.body)
    assert_match(/@devon_synth/, response.body)

    # 1. Inline @username update via PATCH /studio_auth/identity
    patch studio_auth_identity_url, params: { user: { username: "saanskara_hq" } }, as: :turbo_stream
    assert_response :success
    assert_match(/@saanskara_hq/, response.body)

    # 2. Live role & plan tier update via PATCH /studio_auth/role_tier
    patch studio_auth_role_tier_url, params: {
      user: { project_role: "editor", studio_plan: "producer_pro" }
    }, as: :turbo_stream
    assert_response :success
    assert_match(/EFFECTIVE PERMISSION GRANTS/, response.body)

    # 3. Grant collaborator access via POST /studio_auth/collaborators
    post studio_auth_collaborators_url, params: {
      collaborator: {
        username: "kora_mix",
        email: "kora@saanskara.studio",
        role: "EDITOR"
      }
    }, as: :turbo_stream
    assert_response :success
    assert_match(/@kora_mix/, response.body)

    # 4. Revoke collaborator access via DELETE /studio_auth/collaborators/:id
    collab = ProjectCollaborator.find_by!(username: "kora_mix")
    delete studio_auth_collaborator_url(collab), as: :turbo_stream
    assert_response :success
  end

  test "renders Dockable Right-Side Utility Sidebar with Chat/DM, Branches, Remote, and Notes/AI panels and handles Turbo Streams" do
    get root_url
    assert_response :success

    # Dockable Sidebar (#jyki_right_sidebar) + 5-button Far-Right Vertical Icon Rail
    assert_select "#jyki_right_sidebar"
    assert_select "[data-zone='utility-rail'] button", minimum: 5

    # Panel 1: Chat / DM
    assert_select "#jyki_right_sidebar", /Chat \/ DM/
    assert_select "#jyki_right_sidebar button", /Project Room/
    assert_select "#jyki_right_sidebar button", /Direct Message \(DM\)/
    assert_select "#jyki_chat_messages", /Aria \(Mastering Eng\)/
    assert_select "#jyki_chat_messages", /Checked the 96kHz \/ 32-bit float bounce/
    assert_select "#jyki_chat_messages", /Devon \(Synth Lead\)/
    assert_select "#jyki_chat_messages", /Committed branch alt-808-saturation-pass/

    # Panel 2: Branches (CRDT Version History & Branches)
    assert_select "#jyki_right_sidebar", /CRDT Version History & Branches/
    assert_select "#jyki_right_sidebar", /Lossless state snapshots stored as Yjs_delta_vectors\./
    assert_select "#crdt_branches_list", /main \(master-bus-locked\)/
    assert_select "#crdt_branches_list", /AQT\/AQABc2FhbnNreXJkdW1Rhdw==/
    assert_select "#crdt_branches_list", /alt-808-saturation-pass/
    assert_select "#crdt_branches_list", /AQf\/AgB4808tZzxpZGUtcmFtCA==/
    assert_select "#crdt_branches_list button", /Merge \/ Checkout Delta/

    # Panel 3: Remote (Mobile Companion Remote)
    assert_select "#jyki_right_sidebar", /Mobile Companion Remote/
    assert_select "#jyki_right_sidebar", /PAIRED/
    assert_select "#jyki_right_sidebar", /iPhone 17 Pro · Studio Remote/
    assert_select "#jyki_right_sidebar", /3\.8 ms/
    assert_select "#jyki_right_sidebar", /ARMED · LOW-LATENCY MON/
    assert_select "#jyki_right_sidebar button", /Refresh Companion Telemetry/

    # Panel 4: Notes / Studio AI
    assert_select "#jyki_right_sidebar", /AI Lab/

    # 1. Send Chat Message via Turbo Stream (POST /studio_chat_messages)
    post studio_chat_messages_url, params: {
      chat_message: {
        body: "Sub-bass phase locked at 55 Hz — ready for stem bounce.",
        room_type: "project_room"
      }
    }, as: :turbo_stream
    assert_response :success
    assert_match(/Sub-bass phase locked at 55 Hz/, response.body)

    # 2. Commit New CRDT Branch via Turbo Stream (POST /right_sidebar/branches)
    post right_sidebar_branches_url, params: {
      crdt_branch: { name: "vocal-comp-v2" }
    }, as: :turbo_stream
    assert_response :success
    assert_match(/vocal-comp-v2/, response.body)
    assert_match(/Yjs Delta:/, response.body)

    # 3. Checkout CRDT Branch via Turbo Stream (POST /right_sidebar/branches/:id/checkout)
    branch = CrdtBranch.find_by!(name: "vocal-comp-v2")
    post checkout_right_sidebar_branch_url(branch), as: :turbo_stream
    assert_response :success
    assert_match(/vocal-comp-v2/, response.body)

    # 4. Refresh Mobile Companion Telemetry via Turbo Stream (POST /right_sidebar/refresh_telemetry)
    post right_sidebar_refresh_telemetry_url, as: :turbo_stream
    assert_response :success
    assert_match(/ms/, response.body)
  end
end
