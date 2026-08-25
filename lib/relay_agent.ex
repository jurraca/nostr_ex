defmodule NostrEx.RelayAgent do
  @moduledoc """
  Agent mapping relay connections to their active subscriptions.

  State shape: `%{relay_name => %{sub_id => serialized_req_payload}}`.

  This is the source of truth for subscription payloads: it survives socket
  process death, so a reconnecting socket can replay its REQs after coming
  back up (and a crash-respawned socket can restore subscriptions that were
  active before the crash).
  """
  use Agent

  @spec start_link(map()) :: Agent.on_start()
  def start_link(initial_value) do
    Agent.start_link(fn -> initial_value end, name: __MODULE__)
  end

  @spec state() :: %{String.t() => %{String.t() => binary()}}
  def state do
    Agent.get(__MODULE__, & &1)
  end

  @doc "All subscriptions recorded for a relay: %{sub_id => payload}."
  @spec get(String.t()) :: %{String.t() => binary()} | nil
  def get(relay_name) do
    Agent.get(__MODULE__, &Map.get(&1, relay_name))
  end

  @doc "Subscription IDs recorded for a relay."
  @spec subscription_ids(String.t()) :: [String.t()]
  def subscription_ids(relay_name) do
    case get(relay_name) do
      nil -> []
      subs -> Map.keys(subs)
    end
  end

  @spec get_relays_for_sub(String.t()) :: [String.t()]
  def get_relays_for_sub(sub_id) do
    Agent.get(__MODULE__, fn state ->
      state
      |> Enum.filter(fn {_relay, subs} -> Map.has_key?(subs, sub_id) end)
      |> Enum.map(fn {relay, _subs} -> relay end)
    end)
  end

  @spec get_relays_by_sub() :: %{String.t() => [String.t()]}
  def get_relays_by_sub do
    state()
    |> Enum.reduce(%{}, fn {relay_name, subs}, acc ->
      Enum.reduce(Map.keys(subs), acc, fn sub, inner_acc ->
        Map.update(inner_acc, sub, [relay_name], &[relay_name | &1])
      end)
    end)
  end

  @spec get_unique_subscriptions() :: [String.t()]
  def get_unique_subscriptions() do
    Agent.get(__MODULE__, fn state ->
      state |> Map.values() |> Enum.flat_map(&Map.keys/1) |> Enum.uniq()
    end)
  end

  # Records before sending (see Client.subscribe_to_relay): a fast relay
  # rejection must be able to clean up an entry that already exists.
  @spec put_subscription(String.t(), String.t(), binary()) :: :ok
  def put_subscription(relay_name, sub_id, payload) when is_binary(payload) do
    Agent.update(__MODULE__, fn state ->
      subs = Map.get(state, relay_name, %{})
      Map.put(state, relay_name, Map.put(subs, sub_id, payload))
    end)
  end

  @spec delete_subscription(String.t(), String.t()) :: :ok
  def delete_subscription(relay_name, sub_id) do
    Agent.update(__MODULE__, fn state ->
      case Map.fetch(state, relay_name) do
        {:ok, subs} ->
          remaining = Map.delete(subs, sub_id)

          if remaining == %{} do
            Map.delete(state, relay_name)
          else
            Map.put(state, relay_name, remaining)
          end

        # Unknown relay: nothing to clean up; never plant a phantom key.
        :error ->
          state
      end
    end)
  end

  @spec delete_relay(String.t()) :: :ok
  def delete_relay(relay_name) do
    Agent.update(__MODULE__, &Map.delete(&1, relay_name))
  end
end
