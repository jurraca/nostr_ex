defmodule Nostrbase.Application do
  use Application

  def start(_type, _args) do
    children = [
      {Nostrbase.RelayManager, name: RelaySupervisor, strategy: :one_for_one},
      {Registry, [keys: :duplicate, name: Nostrbase.PubSub, partitions: System.schedulers_online()]},
      {Registry, [keys: :unique, name: Nostrbase.RelayRegistry]},
      {Nostrbase.RelayAgent, %{}}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end

  def get_relays() do
    Application.get_env(:nostrbase, :relays)
  end
end
