defmodule LobstersNntp.NntpServer do
  require Logger
  use Task

  # based on http://www.robgolding.com/blog/2019/05/21/tcp-genserver-elixir/
  def start_link(args) do
    Logger.info("[SUP] Starting link for NNTP server")
    Task.start_link(__MODULE__, :accept, [args])
  end

  def accept(args) do
    {:ok, listener} = :gen_tcp.listen(
      args.port,
      [:binary, packet: :line, active: :true, reuseaddr: true]
    )
    Logger.info("[TCP] accepting on port #{args.port}")
    listen(listener)
  end

  def listen(listener) do
    {:ok, socket} = :gen_tcp.accept(listener)
    Logger.info("[TCP] accepted socket")
    {:ok, pid} = DynamicSupervisor.start_child(
      LobstersNntp.NntpSessionSupervisor,
      {LobstersNntp.NntpSession, socket}
    )
    :gen_tcp.controlling_process(socket, pid)
    listen(listener)
  end
end
