defmodule Tasks2Web.Router do
  use Tasks2Web, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_flash
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug Tasks2Web.Plugs.FetchSession
  end

  pipeline :ajax do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :fetch_flash
    plug Tasks2Web.Plugs.FetchSession # FIXME: "FetchUser"
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", Tasks2Web do
    pipe_through :browser

    get "/", PageController, :index
    resources "/tasks", TaskController
    resources "/users", UserController
    resources "/sessions", SessionController, only: [:create, :delete], singleton: true
  end

  scope "/ajax", Tasks2Web do
    pipe_through :ajax
    resources "/time_blocks", TimeBlockController, except: [:new, :edit]
 end

  # Other scopes may use custom stacks.
  # scope "/api", Tasks2Web do
  #   pipe_through :api
  # end
end
