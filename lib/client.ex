defmodule NostrEx.Client do
  @moduledoc """
  Internal client operations for the Nostr protocol.

  This module provides the low-level implementation for NostrEx.
  Most users should use the `NostrEx` module instead.
  """

  alias NostrCore.{Event, Message}
  alias NostrEx.{RelayAgent, RelayManager, Socket, Utils}

  @type failure :: {relay :: String.t() | term(), reason :: term()}

  @type send_result ::
          {:ok, event_id :: binary(), [failure()]}
          | {:error, :no_relays | :unsigned_event | term(), [failure()]}

  # === Event Publishing ===

  @doc """
  Send a signed event as an `%Event{}` struct.

  Fan-out contract shared by all multi-relay operations:

  - `{:ok, value, failures}` - at least one relay accepted the message;
    `failures` lists per-relay problems as `{relay_or_input, reason}` tuples,
    including unknown `send_via` names (`{:name, :not_connected}`).
  - `{:error, reason, failures}` - nothing was delivered. `reason` is
    `:no_relays` when no relay was targeted at all, or a string describing
    why every attempted send failed.

  ## Options
  - `:send_via` - List of relays to send the event to. Defaults to all connected relays.
  """
  @spec send_event(Event.t(), keyword()) :: send_result()
  def send_event(event, opts \\ [])

  def send_event(%Event{} = event, opts) do
    {relay_names, bad_inputs} = get_relays(opts[:send_via])
    payload = serialize(event)

    results =
      Enum.map(relay_names, fn relay ->
        case send_to_relay(relay, payload) do
          :ok -> {:ok, relay}
          {:error, reason} -> {:error, relay, reason}
        end
      end)

    finish_fanout(results, bad_inputs, fn
      :all_failed -> "send failed"
      :nothing_targeted -> :no_relays
    end)
    |> case do
      {:ok, _oks, failures} -> {:ok, event.id, failures}
      {:error, reason, failures} -> {:error, reason, failures}
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
      {:error, reason} -> {:error, {:signing_failed, reason}, []}
    end
  end

  def sign_and_send_event(_event, _signer_or_privkey, _opts),
    do: {:error, {:invalid_event, "must be an %Event{} struct"}, []}

  @spec send_to_relay(atom(), binary()) :: :ok | {:error, atom() | String.t()}
  defp send_to_relay(relay, payload) when is_binary(payload) do
    Socket.send_message(relay, payload)
  end

  # === Subscription Management ===

  @doc """
  Send a Subscription struct to relays.

  This is pure transport: it sends the REQ and records the sub in the
  RelayAgent. It does NOT register any process to receive the subscription's
  messages — call `NostrEx.listen/1` (before sending, to avoid missing early
  events) from the process that should receive them.

  Returns the same fan-out contract as `send_event/2`:

  - `{:ok, sub_id, failures}` when at least one relay accepted the REQ
  - `{:error, :no_relays, failures}` / `{:error, "subscribe failed", failures}`

  ## Options
  - `:send_via` - List of relay names. Defaults to all connected relays.
  """
  @spec send_sub(NostrEx.Subscription.t(), keyword()) ::
          {:ok, String.t(), [failure()]} | {:error, term(), [failure()]}
  def send_sub(%NostrEx.Subscription{id: sub_id, filters: filters}, opts \\ []) do
    message = serialize_subscription(sub_id, filters)
    {relay_names, bad_inputs} = get_relays(opts[:send_via])

    results =
      Enum.map(relay_names, fn relay_name ->
        case subscribe_to_relay(relay_name, sub_id, message) do
          :ok -> {:ok, relay_name}
          {:error, reason} -> {:error, relay_name, reason}
        end
      end)

    finish_fanout(results, bad_inputs, fn
      :all_failed -> "subscribe failed"
      :nothing_targeted -> :no_relays
    end)
    |> case do
      {:ok, _oks, failures} -> {:ok, sub_id, failures}
      {:error, reason, failures} -> {:error, reason, failures}
    end
  end

  @type close_result ::
          {:ok, closed :: [String.t()], Keyword.t()}
          | {:error, String.t(), Keyword.t()}

  @doc """
  Close a subscription by ID.

  Sends CLOSE message to all relays that know about this subscription.

  Returns the fan-out contract: `{:ok, closed_relays, failures}`,
  `{:error, "close failed", failures}` when no relay acknowledged, or
  `{:error, :sub_not_found, []}` for an unknown subscription ID.
  """
  @spec close_sub(String.t()) ::
          {:ok, [String.t()], [failure()]} | {:error, term(), [failure()]}
  def close_sub(sub_id) when is_binary(sub_id) do
    if sub_id not in RelayAgent.get_unique_subscriptions() do
      {:error, :sub_not_found, []}
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

      finish_fanout(results, [], fn
        :all_failed -> "close failed"
        :nothing_targeted -> "close failed"
      end)
      |> case do
        {:ok, oks, failures} -> {:ok, Enum.map(oks, fn {:ok, r} -> r end), failures}
        {:error, reason, failures} -> {:error, reason, failures}
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
    # Record before writing the REQ: a fast relay rejection (CLOSED) must be
    # able to clean up an entry that already exists, never resurrect one.
    :ok = RelayAgent.update(relay_name, sub_id)

    case send_to_relay(relay_name, payload) do
      :ok ->
        :ok

      {:error, reason} ->
        RelayAgent.delete_subscription(relay_name, sub_id)
        {:error, reason}
    end
  end

  def sign_event(%Event{} = event, privkey) when is_binary(privkey) do
    Event.sign(event, privkey)
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

      err ->
        err
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

  # Shared tail of every fan-out operation: merges per-relay failures with
  # rejected inputs and decides between {:ok, oks, failures} and
  # {:error, reason, failures}.
  @spec finish_fanout([{:ok, String.t()} | {:error, String.t(), term()}], [failure()], fun()) ::
          {:ok, [{:ok, String.t()}], [failure()]} | {:error, term(), [failure()]}
  defp finish_fanout(results, bad_inputs, reason_for) do
    {oks, relay_failures} = Enum.split_with(results, &match?({:ok, _}, &1))

    failures =
      Enum.map(relay_failures, fn {:error, relay, reason} -> {relay, reason} end) ++ bad_inputs

    cond do
      oks != [] -> {:ok, oks, failures}
      results == [] and bad_inputs != [] -> {:error, :no_relays, failures}
      results == [] -> {:error, reason_for.(:nothing_targeted), []}
      true -> {:error, reason_for.(:all_failed), failures}
    end
  end

  @spec get_relays(nil | :all | String.t() | [String.t()]) :: {[String.t()], [failure()]}
  defp get_relays(nil), do: get_relays(:all)
  defp get_relays(:all), do: {RelayManager.registered_names(), []}

  # Unknown or disconnected entries are returned as rejected inputs instead
  # of being silently dropped.
  defp get_relays(input) do
    input
    |> List.wrap()
    |> Enum.reduce({[], []}, fn relay, {names, bad} ->
      case normalize(relay) do
        {:ok, name} -> {[name | names], bad}
        {:error, _reason} -> {names, [{relay, :not_connected} | bad]}
      end
    end)
    |> then(fn {names, bad} -> {Enum.reverse(names), Enum.reverse(bad)} end)
  end

  @spec normalize(relay :: term()) :: {:ok, String.t()} | {:error, :not_connected}
  defp normalize(relay) when is_binary(relay) do
    registered = RelayManager.registered_names()

    cond do
      relay in registered ->
        {:ok, relay}

      true ->
        host = relay |> URI.parse() |> Map.get(:host)

        if host do
          name = Utils.name_from_host(host)
          if name in registered, do: {:ok, name}, else: {:error, :not_connected}
        else
          {:error, :not_connected}
        end
    end
  end

  defp normalize(relay), do: {:error, :not_connected}
end
