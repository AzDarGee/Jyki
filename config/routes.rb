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

  # Legacy home index route
  get "home" => "home#index", as: :home

  # Defines the root path route ("/") — Jaku by Saanskara Studios SPA Workstation
  root "workstation#index"
end
