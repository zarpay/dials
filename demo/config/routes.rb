Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  # The app's hand-built dial write surface (the gem ships none by design).
  namespace :admin do
    resources :dials, param: :key, only: %i[index update destroy] do
      member { get :changes }
    end
  end
end
