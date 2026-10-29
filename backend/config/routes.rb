Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  namespace :api do
    namespace :v1 do
      # Liveness: is the process responding? Never touches the database.
      get "health", to: "health#show"
      # Readiness: can the process serve database-backed requests?
      get "ready", to: "ready#show"

      # Read-only football domain. Index-only: no create/update/delete routes
      # exist yet, by design for this milestone.
      resources :competitions, only: [:index]
      resources :teams, only: [:index]
      resources :matches, only: [:index]
      # Seasons must be discoverable by a client. The ML training flow used to
      # hardcode database ids, which are not stable across a re-import.
      resources :seasons, only: [:index]

      # Stored 1X2 predictions. Read-only: inference is requested through the
      # background job (PredictMatchJob), never by a GET, so a client refreshing
      # the app cannot generate model work.
      # index/show read stored predictions; create REQUESTS one. Inference is
      # orchestrated by Predictions::MarketPredictor, never computed in the
      # controller.
      resources :predictions, only: [:index, :show, :create]

      # Which model versions have produced predictions, and how recently.
      get "model_status", to: "model_status#show"
    end
  end

  # Defines the root path route ("/")
  # root "posts#index"
end
