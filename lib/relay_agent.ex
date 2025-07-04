defmodule NostrEx.RelayAgent do
  @moduledoc """
    Agent that maps relay connections to their active subscriptions.
    We use this to manage subscription lifecycle and track which relays have which subscriptions.
  """
  use Agent

  def start_link(initial_value) do
    Agent.start_link(fn -> initial_value end, name: __MODULE__)
  end

  def state do
    Agent.get(__MODULE__, & &1)
  end

  def get(relay_name) do
    Agent.get(__MODULE__, &Map.get(&1, relay_name))
  end

  def get_relays_for_sub(sub_id) do
    Agent.get(__MODULE__, fn state ->
      state
      |> Enum.filter(fn {_relay, subs} -> sub_id in subs end)
      |> Enum.map(fn {relay, _subs} -> relay end)
    end)
  end

  def get_relays_by_sub do
    state()
    |> Enum.reduce(%{}, fn {relay_name, subs}, acc ->
      Enum.map(subs, fn sub ->
        Map.update(acc, sub, [relay_name], fn existing -> [relay_name | existing] end)
      end)
    end)
  end

  def get_unique_subscriptions() do
    Agent.get(__MODULE__, fn state -> state |> Map.values() |> Enum.uniq() end)
  end

  def update(relay_name, sub_id) do
    Agent.update(__MODULE__, fn state ->
      Map.update(state, relay_name, [sub_id], fn existing ->
        if sub_id in existing do
          existing
        else
          [sub_id | existing]
        end
      end)
    end)
  end

  def delete_subscription(relay_name, sub_id) do
    Agent.update(
      __MODULE__,
      &Map.update!(&1, relay_name, fn existing -> List.delete(existing, sub_id) end)
    )
  end

  def delete_relay(relay_name) do
    Agent.update(__MODULE__, &Map.delete(&1, relay_name))
  end
end
