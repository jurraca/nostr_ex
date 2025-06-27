defmodule NostrEx.Client do
  @moduledoc """
    Transmit notes and other stuff via relays.

    Mainly wraps the websocket wlient in `Socket`. When using functions like `send_note` or similar,
    the `opts` arguments will take a `send_via` option which takes relays to send the event to.
    By default it will send to all relays.
  """

  alias Nostr.{Event, Filter, Message}
  alias NostrEx.{RelayAgent, RelayManager, Socket, Utils}

  @doc """
    Send a serialized payload to the `relay`.
    `relay` can either be a PID or a relay name as registered in the `RelayRegistry`.
  """
  def send_event(relay, payload) when is_binary(payload) do
    Socket.send_message(relay, payload)
  end

  @doc """
    Send a kind 1 note.
    Valid `opts`:
      - `send_via`: a list of relays to send the event to.
  """
  def send_note(note, privkey, opts \\ []) do
    do_event_send(privkey, note, &create_note/2, opts)
  end

  @doc """
    Send a kind 23 long-form note.
    Valid `opts`:
      - `send_via`: a list of relays to send the event to.
  """
  def send_long_form(text, privkey, opts \\ []) do
    do_event_send(privkey, text, &create_long_form/2, opts)
  end

  @doc """
    Send a subscription request.
    `filter` is a keyword list of arguments for a `Nostr.Filter` struct.
    Since subscriptions are asynchronous.
  """
  def send_sub(filter, opts \\ []) do
    with {:ok, sub_id, message} <- create_sub(filter),
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
    Close a subscription with ID `sub_id`.
    The subscription `CLOSE` message will be sent to all relays which know about this subscription.
  """
  def close_sub(sub_id) when is_binary(sub_id) do
    with true <- sub_id in RelayAgent.get_unique_subscriptions(),
         relays <- RelayAgent.get_relays_for_sub(sub_id),
         request = Message.close(sub_id) |> Message.serialize() do
      relays
      |> Enum.map(fn relay_name ->
        case send_event(relay_name, request) do
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
    Close a connection to a relay.
  """
  def close_conn(relay_name) do
    case Registry.lookup(NostrEx.RelayRegistry, relay_name) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(RelayManager, pid)
      _ -> {:error, :not_found}
    end
  end

  @doc """
    Create a kind 1 event with content `note`, signed and serialized.
  """
  def create_note(note, privkey) when is_binary(note) do
    note
    |> Event.Note.create()
    |> Map.get(:event)
    |> sign_and_serialize(privkey)
  end

  @doc """
    Create a kind 23 event with content `text`, signed and serialized.
  """
  def create_long_form(text, privkey) do
    Event.create(23, content: text) |> sign_and_serialize(privkey)
  end

  @doc """
    Create a subscription with arguments `opts`, which must be valid fields for a `Filter` struct.
  """
  def create_sub(opts) when is_list(opts) do
    cond do
      # Single filter as keyword list
      Keyword.keyword?(opts) ->
        filter = Map.merge(%Filter{}, Enum.into(opts, %{}))
        do_create_sub([filter])

      # Multiple filters as list of keyword lists
      Enum.all?(opts, &Keyword.keyword?/1) ->
        opts
        |> Enum.map(&Map.merge(%Filter{}, Enum.into(&1, %{})))
        |> do_create_sub()

      true ->
        {:error, "Invalid filter format"}
    end
  end

  @doc """
    Subscribe with a serialized "REQ" `payload` with ID `sub_id` via relay with registered name `relay_name`.
  """
  def subscribe(relay_name, sub_id, payload) when is_binary(sub_id) do
    with :ok <- send_event(relay_name, payload),
         :ok <- RelayAgent.update(relay_name, sub_id) do
      :ok
    end
  end

  def subscribe(_, sub_id, _), do: {:error, "invalid sub_id format, got #{sub_id}"}

  @doc """
    Sign and serialize an `event` with private key `privkey`.
  """
  def sign_and_serialize(%Event{} = event, privkey) do
    event
    |> Event.sign(privkey)
    |> Message.create_event()
    |> Message.serialize()
  end

  def sign_and_serialize(_, _),
    do: {:error, "invalid event provided, must be an %Event{} struct."}

  defp do_event_send(privkey, arg, create_fun, opts) do
    with relay_names = get_relays(opts[:send_via]),
         json_event <- create_fun.(arg, privkey) do
      results = Enum.map(relay_names, &send_event(&1, json_event))

      case Enum.all?(results, &(&1 == :ok)) do
        true -> {:ok, :sent}
        false -> {:error, Enum.filter(results, &match?(:error, &1))}
      end
    end
  end

  defp do_create_sub(filters) when is_list(filters) do
    sub_id = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

    msg =
      filters
      |> Message.request(sub_id)
      |> Message.serialize()

    {:ok, sub_id, msg}
  end

  defp get_relays(nil), do: get_relays(:all)
  defp get_relays(:all), do: RelayManager.registered_names()

  defp get_relays([_h | _t] = relay_list) do
    Enum.map(relay_list, fn relay ->
      cond do
        relay in RelayManager.registered_names() -> relay
        is_binary(relay) -> relay |> URI.parse() |> Map.get(:host) |> Utils.name_from_host()
        is_pid(relay) and relay in RelayManager.active_pids() -> relay
        true -> {:error, "invalid relay name, got #{relay}"}
      end
    end)
  end

  defp get_relays(relay_list), do: {:error, "invalid relay list provided, got: #{relay_list}"}
end
