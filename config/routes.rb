# frozen_string_literal: true

Rails.application.routes.draw do
  devise_for :users, controllers: {
    sessions: "users/sessions",
    registrations: "users/registrations",
    omniauth_callbacks: "users/omniauth_callbacks"
  }

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/*
  get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker
  get "manifest" => "rails/pwa#manifest", as: :pwa_manifest

  # Stateless SPA Turbo Stream & JSON endpoints (never push browser URL history)
  scope :workstation, controller: :workstation do
    post "tracks", action: :create_track, as: :workstation_tracks
    delete "tracks/:id", action: :destroy_track, as: :workstation_track
    patch "mixer", action: :update_mixer, as: :workstation_mixer
    post "ai_analysis", action: :ai_analysis, as: :workstation_ai_analysis
  end

  # Studio Auth RBAC, Identity & Project Collaborator ACL Turbo Stream endpoints
  scope :studio_auth, controller: :studio_auth do
    patch "identity", action: :update_identity, as: :studio_auth_identity
    patch "role_tier", action: :update_role_tier, as: :studio_auth_role_tier
    post "collaborators", action: :create_collaborator, as: :studio_auth_collaborators
    delete "collaborators/:id", action: :destroy_collaborator, as: :studio_auth_collaborator
  end

  # Dockable Right-Side Utility Sidebar (Chat / DM, CRDT Branches, Remote, Studio Notes)
  post "studio_chat_messages" => "right_sidebar#create_message", as: :studio_chat_messages
  scope :right_sidebar, controller: :right_sidebar do
    post "branches", action: :commit_branch, as: :right_sidebar_branches
    post "branches/:id/checkout", action: :checkout_branch, as: :checkout_right_sidebar_branch
    post "refresh_telemetry", action: :refresh_telemetry, as: :right_sidebar_refresh_telemetry
    post "save_note", action: :save_note, as: :right_sidebar_save_note
  end

  # Legacy home index route
  get "home" => "home#index", as: :home

  # Defines the root path route ("/") — Jaku by Saanskara Studios SPA Workstation
  root "workstation#index"
end
