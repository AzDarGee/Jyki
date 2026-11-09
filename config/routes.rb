# frozen_string_literal: true

Rails.application.routes.draw do
  devise_for :users, controllers: {
    sessions: "users/sessions"
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

  # Legacy home index route
  get "home" => "home#index", as: :home

  # Defines the root path route ("/") — Jaku by Saanskara Studios SPA Workstation
  root "workstation#index"
end
