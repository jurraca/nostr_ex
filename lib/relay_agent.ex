defmodule Nostrbase.RelayAgent do
  @moduledoc """
    State machine that maps PIDs holding relay websocket connections and the subscriptions active on those connections.
    We use this to manage the state of the subscription lifecycle.
  """
  use Agent

  def start_link(initial_value) do
    Agent.start_link(fn -> initial_value end, name: __MODULE__)
  end

  def state do
    Agent.get(__MODULE__, & &1)
  end

  def get(key) do
    Agent.get(__MODULE__, &Map.get(&1, key))
  end

  def update(pid, sub_id) do
    Agent.update(__MODULE__, fn state ->
      Map.update(state, pid, [sub_id], fn existing ->
        if sub_id in existing do
          existing
        else
          [sub_id | existing]
        end
      end)
    end)
  end

  def delete(pid, sub_id) do
    Agent.update(
      __MODULE__,
      &Map.update!(&1, pid, fn existing -> List.delete(existing, sub_id) end)
    )
  end

  def delete(pid) do
    Agent.update(__MODULE__, &Map.delete(&1, pid))
  end
end
