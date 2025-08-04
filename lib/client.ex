defmodule NostrEx.Client do
  @moduledoc """
  Client operations for the Nostr protocol.

  This module handles the core protocol operations like signing events,
  serializing messages, and managing the WebSocket communication layer.
  Most users should use the higher-level `NostrEx` module instead.

  ## Event Creation and Signing

      iex> Client.create_note("Hello", private_key)
      "{\"content\":\"Hello\",\"created_at\":...}"

  ## Subscription Management

      iex> Client.send_sub([authors: [pubkey], kinds: [1]])
      {:ok, "subscription_id"}
  """

  alias Nostr.{Event, Filter, Message}
  alias NostrEx.{RelayAgent, RelayManager, Socket, Utils}

  require Logger

  # === Event Publishing ===

  @doc """
  Send a signed event as an `%Event{}` struct.

  ## Options
  - `:send_via` - List of relays to send the event to. Defaults to all connected relays.
  """
  @spec send_event(Event.t(), keyword()) ::
          {:ok, binary()} | {:error, String.t() | [String.t()]}
  def send_event(event, opts \\ [])

  def send_event(%Nostr.Event{} = event, opts) do
    with relay_names = get_relays(opts[:send_via]),
         true <- relay_names != [],
         payload <- serialize(event) do
      {oks, errors} =
        relay_names
        |> Enum.map(&send_event_serialized(&1, payload))
        |> Enum.split_with(&match?(:ok, &1))

      count_errors = Enum.count(errors)
      cond do
        oks == [] ->
          errors = Keyword.values(errors)
          Logger.error("#{count_errors} send(s) failed with errors: #{Enum.join(errors, ", ")}")
          {:error, errors}
        errors != [] ->
          Logger.error("#{event.id}: #{Enum.count(oks)} succeeded, #{count_errors} send(s) failed with errors: #{Enum.join(errors, ", ")}")
          {:ok, event.id}
        true ->
          {:ok, event.id}
      end
    else
      {:error, _} = err -> err
      false -> {:error, "no valid relays found, got: #{inspect(opts[:send_via])}"}
    end
  end

  @doc """
  Send an event and the private key or Signer process to sign the event with.
  """
  def sign_and_send_event(event, signer_or_privkey, opts \\ [])

  @spec sign_and_send_event(Event.t(), binary() | struct(), keyword()) ::
          {:ok, binary()} | {:error, String.t() | [String.t()]}
  def sign_and_send_event(%Event{} = event, signer_or_privkey, opts) do
    case sign_event(event, signer_or_privkey) do
      {:ok, signed_event} -> send_event(signed_event, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  def sign_and_send_event(_event, _signer_or_privkey, _opts),
    do: {:error, "invalid event provided, must be an %Event{} struct."}

  @doc """
  Send a serialized payload to a specific relay.

  `relay` must be a relay name registered in the RelayRegistry.
  """
  @spec send_event_serialized(atom(), binary()) :: :ok | {:error, atom() | String.t()}
  def send_event_serialized(relay, payload) when is_binary(payload) do
    Socket.send_message(relay, payload)
  end

  # === Subscription Management ===

  @doc """
  Send a subscription request.

  `filter` can be:
  - A keyword list of filter arguments
  - A list of keyword lists for multiple filters

  Returns `{:ok, subscription_id}` on success.
  """
  @spec send_sub(keyword() | [keyword()], keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def send_sub(filter, opts \\ []) do
    with {:ok, filters} <- create_filters(filter),
         {:ok, sub_id, message} <- create_subscription_message(filters),
         {:ok, _pid} <- Registry.register(NostrEx.PubSub, sub_id, nil) do
      opts[:send_via]
      |> get_relays()
      |> Enum.each(fn relay_name ->
        subscribe(relay_name, sub_id, message)
      end)

      {:ok, sub_id}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Close a subscription by ID.

  Sends CLOSE message to all relays that know about this subscription.
  """
  @spec close_sub(String.t()) :: {:ok, [any()]} | {:error, String.t() | [any()]}
  def close_sub(sub_id) when is_binary(sub_id) do
    with true <- sub_id in RelayAgent.get_unique_subscriptions(),
         relays <- RelayAgent.get_relays_for_sub(sub_id),
         request = Message.close(sub_id) |> Message.serialize() do
      relays
      |> Enum.map(fn relay_name ->
        case send_event_serialized(relay_name, request) do
          {:ok, _} -> RelayAgent.delete_subscription(relay_name, sub_id)
          err -> err
        end
      end)
      |> NostrEx.Utils.collect()
    else
      false ->
        {:error, "subscription ID not found: #{sub_id}"}

      _ ->
        {:error, "could not get relays for sub_id: #{sub_id}"}
    end
  end

  @doc """
  Close a connection to a relay by name or pid.
  """
  @spec close_conn(atom()) :: :ok | {:error, :not_found}
  def close_conn(relay_name) when is_atom(relay_name) do
    case Registry.lookup(NostrEx.RelayRegistry, relay_name) do
      [{pid, _}] -> close_conn(pid)
      _ -> {:error, :not_found}
    end
  end

  def close_conn(pid) when is_pid(pid), do: DynamicSupervisor.terminate_child(RelayManager, pid)
  def close_conn(_), do: {:error, :not_found}

  @doc """
  Create filters from keyword list(s).

  Returns `{:ok, [Filter.t()]}` on success.
  """
  @spec create_filters(keyword() | [keyword()]) :: {:ok, [Filter.t()]} | {:error, String.t()}
  def create_filters(opts) when is_list(opts) do
    case opts do
      [] ->
        {:ok, []}

      [{_key, _value} | _] ->
        filter = Map.merge(%Filter{}, Enum.into(opts, %{}))
        {:ok, [filter]}

      filters when is_list(hd(filters)) ->
        case Enum.all?(filters, &Keyword.keyword?/1) do
          true ->
            processed_filters = Enum.map(filters, &Map.merge(%Filter{}, Enum.into(&1, %{})))
            {:ok, processed_filters}

          false ->
            {:error, "Invalid filter format - all elements must be keyword lists"}
        end

      _ ->
        {:error, "Invalid filter format"}
    end
  end

  def create_filters(_opts), do: {:error, "Invalid filter format"}

  @doc """
  Create a subscription message with the given filters.

  Returns `{:ok, subscription_id, serialized_message}`.
  """
  @spec create_subscription_message([Filter.t()]) :: {:ok, String.t(), binary()}
  def create_subscription_message(filters) when is_list(filters) do
    sub_id = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

    msg =
      filters
      |> Message.request(sub_id)
      |> Message.serialize()

    {:ok, sub_id, msg}
  end

  @doc """
  Subscribe to a relay with a specific subscription ID and message.
  """
  @spec subscribe(atom(), String.t(), binary()) :: :ok | {:error, String.t()}
  def subscribe(relay_name, sub_id, payload) when is_binary(sub_id) do
    with :ok <- send_event_serialized(relay_name, payload),
         :ok <- RelayAgent.update(relay_name, sub_id) do
      :ok
    end
  end

  def subscribe(_, sub_id, _), do: {:error, "invalid sub_id format, got #{sub_id}"}

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

  @spec get_relays(nil | :all | [atom() | pid() | String.t()]) :: [atom() | pid() | {:error, String.t()}]
  defp get_relays(nil), do: get_relays(:all)
  defp get_relays(:all), do: RelayManager.registered_names()

  defp get_relays([_h | _t] = relay_list) do
  {oks, errors} =
    relay_list
    |> Enum.map(&normalize(&1))
    |> Enum.split_with(&is_atom(&1))

    Logger.error(Enum.join(errors, ", "))
    oks
  end

  defp get_relays(relay_list) do
    Logger.error("invalid relay list provided, got: #{Enum.join(relay_list, ", ")}")
    []
  end

  defp normalize(relay) do
    cond do
      relay in RelayManager.registered_names() ->
        relay

      is_binary(relay) ->
        host = relay |> URI.parse() |> Map.get(:host)

        with true <- !is_nil(host),
             atom_name = Utils.name_from_host(host),
             true <- atom_name in RelayManager.registered_names() do
          atom_name
        else
          _ ->
            "relay not connected or invalid, got #{relay}"
        end

      true ->
        "invalid relay name, got #{relay}"
    end
  end
end
