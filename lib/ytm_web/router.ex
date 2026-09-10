defmodule YtmWeb.Router do
  use YtmWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {YtmWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", YtmWeb do
    pipe_through :browser

    live "/", HomeLive
    live "/dashboard", DashboardLive
    live "/gpio", GPIOLive
    get "/loading", LoadingController, :show
  end

  # Other scopes may use custom stacks.
  # scope "/api", YtmWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard for demonstration purposes
  #
  import Phoenix.LiveDashboard.Router

  scope "/dev" do
    pipe_through :browser

    live_dashboard "/dashboard", metrics: YtmWeb.Telemetry
  end
end
