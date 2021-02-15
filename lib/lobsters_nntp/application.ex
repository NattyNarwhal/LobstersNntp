defmodule LobstersNntp.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  def start(_type, _args) do
    children = [
      {LobstersNntp.LobstersClient, %{}},
      {LobstersNntp.MboxWorker, %{}},
      {LobstersNntp.NntpServer, %{port: Application.get_env(:lobsters_nntp, :port)}},
      # This handles the clients for the server
      {DynamicSupervisor, strategy: :one_for_one, name: LobstersNntp.NntpSessionSupervisor}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: LobstersNntp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
