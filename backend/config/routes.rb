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
    end
  end

  # Defines the root path route ("/")
  # root "posts#index"
end
