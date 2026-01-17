defmodule NostrEx.Client do
  @moduledoc """
  Internal client operations for the Nostr protocol.

  This module provides the low-level implementation for NostrEx.
  **Most users should use the `NostrEx` module instead.**

  ## Public API (via NostrEx)

  - `NostrEx.create_event/2` - Create events
  - `NostrEx.sign_event/2` - Sign events  
  - `NostrEx.send_event/2` - Send signed events
  - `NostrEx.create_sub/1` - Create subscriptions
  - `NostrEx.send_sub/2` - Send subscriptions
  - `NostrEx.close_sub/1` - Close subscriptions
  """

  alias Nostr.{Event, Message}
  alias NostrEx.{RelayAgent, RelayManager, Socket, Utils}


  # === Event Publishing ===

  @doc """
  Send a signed event as an `%Event{}` struct.

  ## Options
  - `:send_via` - List of relays to send the event to. Defaults to all connected relays.
  """
  @type send_result ::
          {:ok, event_id :: binary(), failures :: [{String.t(), term()}]}
          | {:error, failures :: [{String.t() | atom(), term()}]}

  @spec send_event(Event.t(), keyword()) :: send_result()
  def send_event(event, opts \\ [])

  def send_event(%Nostr.Event{} = event, opts) do
    relay_names = get_relays(opts[:send_via])

    if relay_names == [] do
      {:error, [{:no_relays, "no valid relays found, got: #{inspect(opts[:send_via])}"}]}
    else
      payload = serialize(event)

      results =
        relay_names
        |> Enum.map(fn relay ->
          case send_to_relay(relay, payload) do
            :ok -> {:ok, relay}
            {:error, reason} -> {:error, relay, reason}
          end
        end)

      {successes, failures} =
        Enum.split_with(results, &match?({:ok, _}, &1))

      failure_tuples = Enum.map(failures, fn {:error, relay, reason} -> {relay, reason} end)

      case successes do
        [] -> {:error, failure_tuples}
        _ -> {:ok, event.id, failure_tuples}
      end
    end
  end

  @doc """
  Send an event and the private key or Signer process to sign the event with.
  """
  def sign_and_send_event(event, signer_or_privkey, opts \\ [])

  @spec sign_and_send_event(Event.t(), binary() | struct(), keyword()) :: send_result()
  def sign_and_send_event(%Event{} = event, signer_or_privkey, opts) do
    case sign_event(event, signer_or_privkey) do
      {:ok, signed_event} -> send_event(signed_event, opts)
      {:error, reason} -> {:error, [{:signing_failed, reason}]}
    end
  end

  def sign_and_send_event(_event, _signer_or_privkey, _opts),
    do: {:error, [{:invalid_event, "must be an %Event{} struct"}]}

  @spec send_to_relay(atom(), binary()) :: :ok | {:error, atom() | String.t()}
  defp send_to_relay(relay, payload) when is_binary(payload) do
    Socket.send_message(relay, payload)
  end

  # === Subscription Management ===

  @doc """
  Send a Subscription struct to relays.

  ## Options
  - `:send_via` - List of relay names. Defaults to all connected relays.
  """
  @spec send_sub(NostrEx.Subscription.t(), keyword()) :: :ok | {:error, String.t()}
  def send_sub(%NostrEx.Subscription{id: sub_id, filters: filters}, opts \\ []) do
    message = serialize_subscription(sub_id, filters)
    relay_names = get_relays(opts[:send_via])
    {:ok, _pid} = Registry.register(NostrEx.PubSub, sub_id, nil)

    case relay_names do
      [] ->
        {:error, "no relays connected"}

      _ ->
        Enum.each(relay_names, fn relay_name ->
          subscribe_to_relay(relay_name, sub_id, message)
        end)

        {:ok, sub_id}
    end
  end

  @type close_result ::
          {:ok, closed :: [String.t()], failures :: [{String.t(), term()}]}
          | {:error, failures :: [{String.t() | atom(), term()}]}

  @doc """
  Close a subscription by ID.

  Sends CLOSE message to all relays that know about this subscription.

  Returns `{:ok, closed_relays, failures}` where failures is a list of
  `{relay_name, reason}` tuples, or `{:error, failures}` if all failed.
  """
  @spec close_sub(String.t()) :: close_result()
  def close_sub(sub_id) when is_binary(sub_id) do
    if sub_id not in RelayAgent.get_unique_subscriptions() do
      {:error, [{:not_found, "subscription ID not found: #{sub_id}"}]}
    else
      relays = RelayAgent.get_relays_for_sub(sub_id)
      request = Message.close(sub_id) |> Message.serialize()

      results =
        Enum.map(relays, fn relay_name ->
          case send_to_relay(relay_name, request) do
            :ok ->
              RelayAgent.delete_subscription(relay_name, sub_id)
              {:ok, relay_name}

            {:error, reason} ->
              {:error, relay_name, reason}
          end
        end)

      {successes, failures} = Enum.split_with(results, &match?({:ok, _}, &1))

      closed_relays = Enum.map(successes, fn {:ok, relay} -> relay end)
      failure_tuples = Enum.map(failures, fn {:error, relay, reason} -> {relay, reason} end)

      case successes do
        [] -> {:error, failure_tuples}
        _ -> {:ok, closed_relays, failure_tuples}
      end
    end
  end

  @doc """
  Close a connection to a relay by name or pid.
  """
  @spec close_conn(String.t()) :: :ok | {:error, :not_found}
  def close_conn(relay_name) when is_binary(relay_name) do
    case Registry.lookup(NostrEx.RelayRegistry, relay_name) do
      [{pid, _}] -> close_conn(pid)
      _ -> {:error, :not_found}
    end
  end

  def close_conn(pid) when is_pid(pid), do: DynamicSupervisor.terminate_child(RelayManager, pid)
  def close_conn(_), do: {:error, :not_found}

  @spec subscribe_to_relay(atom(), String.t(), binary()) :: :ok | {:error, String.t()}
  defp subscribe_to_relay(relay_name, sub_id, payload) when is_binary(sub_id) do
    with :ok <- send_to_relay(relay_name, payload),
         :ok <- RelayAgent.update(relay_name, sub_id) do
      :ok
    end
  end

  def sign_event(%Event{} = event, privkey) when is_binary(privkey) do
    try do
      signed_event = Event.sign(event, privkey)
      {:ok, signed_event}
    catch
      _ -> {:error, "failed to sign event"}
    end
  end

  def sign_event(%Event{} = event, signer_pid) when is_pid(signer_pid) do
    case NostrEx.Signer.Local.sign_event(signer_pid, event) do
      {:ok, signed_event} ->
        {:ok, signed_event}

      {:error, reason} ->
            {:error, reason}
    end
  end

  def sign_event(%Event{}, signer_or_privkey),
    do:
      {:error,
       "signer must be a binary private key or struct implementing NostrEx.Signer, got: #{inspect(signer_or_privkey)}"}

  @doc """
  Sign an event with a private key or signer and serialize it as a JSON message.
  """
  @spec sign_and_serialize(Event.t(), binary() | struct()) ::
          {:ok, binary(), binary()} | {:error, String.t()}
  def sign_and_serialize(%Event{} = event, signer_or_privkey) do
    case sign_event(event, signer_or_privkey) do
      {:ok, signed_event} ->
        serialized = serialize(signed_event)
        {:ok, signed_event.id, serialized}
      err -> err
    end
  end

  def sign_and_serialize(_, _),
    do: {:error, "invalid event provided, must be an %Event{} struct."}

  def serialize(%Event{} = signed_event) do
    signed_event
    |> Message.create_event()
    |> Message.serialize()
  end

  defp serialize_subscription(sub_id, filters) do
    filters
    |> Message.request(sub_id)
    |> Message.serialize()
  end

  @spec get_relays(nil | :all | [String.t()]) :: [String.t()]
  defp get_relays(nil), do: get_relays(:all)
  defp get_relays(:all), do: RelayManager.registered_names()

  defp get_relays([_h | _t] = relay_list) do
    {oks, _errors} =
      relay_list
      |> Enum.map(&normalize(&1))
      |> Enum.split_with(&is_binary(&1))

    oks
  end

  defp get_relays(_relay_list), do: []

  defp normalize(relay) when is_binary(relay) do
    # Try as-is first (already a registered name)
    if relay in RelayManager.registered_names() do
      relay
    else
      # Try parsing as URL and extracting host
      host = relay |> URI.parse() |> Map.get(:host)

      if host do
        name = Utils.name_from_host(host)

        if name in RelayManager.registered_names() do
          name
        else
          {:error, "relay not connected or invalid, got #{relay}"}
        end
      else
        {:error, "relay not connected or invalid, got #{relay}"}
      end
    end
  end

  defp normalize(relay), do: {:error, "invalid relay name, got #{inspect(relay)}"}
end
