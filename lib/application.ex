defmodule NostrEx.Application do
  use Application

  def start(_type, _args) do
    children = [
      {DynamicSupervisor, name: NostrEx.RelayManager, strategy: :one_for_one},
      {Registry,
       [keys: :duplicate, name: NostrEx.PubSub, partitions: System.schedulers_online()]},
      {Registry, [keys: :unique, name: NostrEx.RelayRegistry]},
      {NostrEx.RelayAgent, %{}}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end

  def get_relays() do
    Application.get_env(:nostr_ex, :relays)
  end
end
