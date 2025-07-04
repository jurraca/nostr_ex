defmodule NostrEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :nostr_ex,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: docs(),
      aliases: [
        "deps.get": ["deps.get", "deps.nix"],
        "deps.update": ["deps.update", "deps.nix"]
      ]
    ]
  end

  defp package do
    [
      name: "nostr_ex",
      maintainers: ["jurraca <julienu@pm.me"],
      files: ~w(lib .formatter.exs mix.exs README* LICENSE* CHANGELOG*),
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/jurraca/nostr_ex",
        "Nostr specs" => "https://github.com/nostr-protocol/nips"
      }
    ]
  end

  defp docs do
    [
      authors: ["jurraca <julienu@pm.me>"],
      main: "overview",
      api_reference: false,
      formatters: ["html"],
      source_url: "https://github.com/jurraca/nostr_ex"
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {NostrEx.Application, []},
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:nostr_lib, "~> 0.1.1"},
      {:mint_web_socket, "~> 1.0.3"},
      {:req, "0.5.0"}
    ]
  end
end
