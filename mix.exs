defmodule Nostrbase.MixProject do
  use Mix.Project

  def project do
    [
      app: :nostrbase,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {Nostrbase.Application, []},
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:nostr_lib, "~> 0.1.1"},
      {:mint_web_socket, "~> 1.0.3"}
    ]
  end
end
