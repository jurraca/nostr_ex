defmodule NostrEx.Supervisor do
  @moduledoc """
  Embeddable supervision tree for nostr_ex.

  Started automatically by `NostrEx.Application` unless
  `config :nostr_ex, autostart: false` is set. Host applications may instead
  embed it anywhere in their own tree:

      children = [
        {NostrEx.Supervisor, max_restarts: 10}
      ]

  The tree is a singleton (fixed process names), so exactly one instance may
  run per node.

  ## Options

    * `:partitions` - Registry partitions for the pubsub dispatch layer.
      Defaults to `System.schedulers_online/0`.
    * `:max_restarts` / `:max_seconds` / `:strategy` - passed through to the
      relay DynamicSupervisor. Defaults: 3 restarts / 5 seconds / `:one_for_one`.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    children = [
      {DynamicSupervisor,
       Keyword.merge(
         [strategy: :one_for_one, name: NostrEx.RelayManager],
         Keyword.take(opts, [:max_restarts, :max_seconds, :max_children, :strategy])
       )},
      {Registry,
       [
         keys: :duplicate,
         name: NostrEx.PubSub,
         partitions: Keyword.get(opts, :partitions, System.schedulers_online())
       ]},
      {Registry, keys: :unique, name: NostrEx.RelayRegistry},
      {NostrEx.RelayAgent, %{}}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
