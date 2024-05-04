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
    DynamicSupervisor.start_child(RelayManager, {WsClient, relay_url})
  end

  def active_pids() do
    RelayManager
    |> DynamicSupervisor.which_children()
    |> Enum.map(&get_pid/1)
  end

  def get_active_subscriptions() do
    active_pids()
    |> Enum.map(fn pid -> WsClient.subscriptions(pid) end)
    |> List.flatten()
    |> Enum.uniq()
  end

#  def get_active_subscriptions_by_relay() do
#    active_pids() |> Enum.map(fn pid -> {WsClient.url(pid), WsClient.subscriptions(pid)} end)
#  end

  defp get_pid({:undefined, pid, :worker, [WsClient]}), do: pid
end
