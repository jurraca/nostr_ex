defmodule Nostrbase.RelayManager do
  @moduledoc """
  A Dynamic Supervisor which supervises connections to relays.
  This module provides a few functions to faciliate getting the status of individual websocket conns.
  """

  use DynamicSupervisor

  alias Nostrbase.WsClient

  def start_link(opts) do
    DynamicSupervisor.start_link(opts)
  end

  @impl true
  def init(args) do
    {:ok, args}
  end

  def connect(relay_url) do
    DynamicSupervisor.start_child(RelayManager, {WsClient, %{relay_url: relay_url, subscriptions: []}})
  end

  def active_pids() do
    RelayManager
    |> DynamicSupervisor.which_children()
    |> Enum.map(&get_pid/1)
  end

  def get_active_subscriptions() do
    active_pids()
    |> Enum.map(fn pid -> get_subs(pid) end)
    |> List.flatten()
    |> Enum.reject(&is_nil(&1))
    |> Enum.uniq()
  end

  def get_active_subscriptions_by_relay() do
    active_pids() 
    |> Enum.map(fn pid -> 
        case get_subs(pid) do
            {:ok, state} -> state
            _ -> nil
        end
    end)
    |> Enum.reject(&is_nil(&1))
  end

  def get_state(pid) do
     GenServer.call(pid, :get_state)
  end

  defp get_pid({:undefined, pid, :worker, [WsClient]}), do: pid

  defp get_subs(pid) do
      case send(pid, :get_state) do
          {:ok, %{subscriptions: subs}} -> subs
          _ -> nil
      end
  end
end
