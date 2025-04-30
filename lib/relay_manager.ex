defmodule Nostrbase.RelayManager do
  @moduledoc """
  A Dynamic Supervisor which supervises connections to relays.
  This module provides a few functions to faciliate getting the status of individual websocket conns.
  """

  use DynamicSupervisor
  alias Nostrbase.{RelayAgent, Socket}

  @name RelaySupervisor

  def start_link(opts) do
    DynamicSupervisor.start_link(opts)
  end

  @impl true
  def init(opts) do
    DynamicSupervisor.init(opts)
  end

  def connect(relay_url) do
   with {:ok, pid} <- DynamicSupervisor.start_child(@name, {Socket, %{url: relay_url}}),
        {:ok, _} <- Socket.connect(pid) do
      {:ok, pid}
    end
  end

  def relays() do
    DynamicSupervisor.which_children(@name)
  end

  def active_pids() do
    @name
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
    active_pids() |> Enum.map(fn pid -> {pid, get_subs(pid)} end)
  end

  def get_relays_by_sub do
    state = RelayAgent.state()

    Enum.reduce(state, %{}, fn {pid, subs}, acc ->
      Enum.map(subs, fn sub ->
        Map.update(acc, sub, [pid], fn existing -> [pid | existing] end)
      end)
    end)
  end

  defp get_pid({:undefined, pid, :worker, [Socket]}), do: pid

  defp get_subs(pid), do: RelayAgent.get(pid)
end
