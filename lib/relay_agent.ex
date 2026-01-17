defmodule NostrEx.RelayAgent do
  @moduledoc """
    Agent that maps relay connections to their active subscriptions.
    We use this to manage subscription lifecycle and track which relays have which subscriptions.
  """
  use Agent

  @spec start_link(map()) :: Agent.on_start()
  def start_link(initial_value) do
    Agent.start_link(fn -> initial_value end, name: __MODULE__)
  end

  @spec state() :: %{String.t() => [String.t()]}
  def state do
    Agent.get(__MODULE__, & &1)
  end

  @spec get(String.t()) :: [String.t()] | nil
  def get(relay_name) do
    Agent.get(__MODULE__, &Map.get(&1, relay_name))
  end

  @spec get_relays_for_sub(String.t()) :: [String.t()]
  def get_relays_for_sub(sub_id) do
    Agent.get(__MODULE__, fn state ->
      state
      |> Enum.filter(fn {_relay, subs} -> sub_id in subs end)
      |> Enum.map(fn {relay, _subs} -> relay end)
    end)
  end

  @spec get_relays_by_sub() :: %{String.t() => [String.t()]}
  def get_relays_by_sub do
    state()
    |> Enum.reduce(%{}, fn {relay_name, subs}, acc ->
      Enum.map(subs, fn sub ->
        Map.update(acc, sub, [relay_name], fn existing -> [relay_name | existing] end)
      end)
    end)
  end

  @spec get_unique_subscriptions() :: [String.t()]
  def get_unique_subscriptions() do
    Agent.get(__MODULE__, fn state -> state |> Map.values() |> List.flatten() |> Enum.uniq() end)
  end

  @spec update(String.t(), String.t()) :: :ok
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

  @spec delete_subscription(String.t(), String.t()) :: :ok
  def delete_subscription(relay_name, sub_id) do
    Agent.update(
      __MODULE__,
      &Map.update!(&1, relay_name, fn existing -> List.delete(existing, sub_id) end)
    )
  end

  @spec delete_relay(String.t()) :: :ok
  def delete_relay(relay_name) do
    Agent.update(__MODULE__, &Map.delete(&1, relay_name))
  end
end
