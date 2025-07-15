defmodule NostrEx.MixProject do
  use Mix.Project

  @version "0.1.0"
  def project do
    [
      app: :nostr_ex,
      version: @version,
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: docs()
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
      main: "NostrEx",
      api_reference: false,
      formatters: ["html"],
      source_ref: "v#{@version}",
      source_url: "https://github.com/jurraca/nostr_ex",
      extras: ["README.md"]
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
      {:req, "0.5.0"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false, warn_if_outdated: true}
    ]
  end
end
