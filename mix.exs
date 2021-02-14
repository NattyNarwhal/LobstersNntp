defmodule LobstersNntp.MixProject do
  use Mix.Project

  def project do
    [
      app: :lobsters_nntp,
      version: "0.1.0",
      elixir: "~> 1.10",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {LobstersNntp.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:httpoison, "~> 1.8"},
      {:poison, "~> 3.1"},
      {:amnesia, "~> 0.2.0"},
      {:gen_smtp, "~> 1.1.0"}
    ]
  end
end
