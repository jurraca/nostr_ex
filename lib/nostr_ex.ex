defmodule NostrEx do
  @moduledoc """
  A Nostr client library for Elixir applications.

  ## Quick Start

      # Connect to a relay
      {:ok, "relay.damus.io"} = NostrEx.connect("wss://relay.damus.io")

      # Create and send a subscription
      {:ok, sub} = NostrEx.create_sub(authors: [pubkey], kinds: [1])
      :ok = NostrEx.send_sub(sub)

      # Listen for events
      NostrEx.listen(sub)

      # Create, sign, and send an event
      {:ok, event} = NostrEx.create_event(1, content: "Hello Nostr!")
      {:ok, signed} = NostrEx.sign_event(event, private_key)
      {:ok, event_id, []} = NostrEx.send_event(signed)

  ## Modules

  - `NostrEx.Subscription` - Subscription struct and creation
  - `NostrEx.Client` - Internal client operations
  - `NostrEx.RelayManager` - Relay connection management
  """

  alias NostrEx.{Client, RelayAgent, RelayManager, Subscription}
  alias Nostr.Event

  @type relay_name :: String.t()
  @type sub_id :: String.t()
  @type event_id :: String.t()

  # Relay Management

  @doc """
  Connect to a relay.

  ## Examples

      iex> NostrEx.connect("wss://relay.damus.io")
      {:ok, "relay.damus.io"}

      iex> NostrEx.connect("invalid")
      {:error, "Invalid URL"}
  """
  @spec connect(binary()) :: {:ok, relay_name()} | {:error, String.t()}
  def connect(relay_url) when is_binary(relay_url), do: RelayManager.connect(relay_url)

  @doc """
  Disconnect from a relay.

  Accepts a relay URL or its registered name.

  ## Examples

      iex> NostrEx.disconnect("wss://relay.damus.io")
      :ok

      iex> NostrEx.disconnect("relay.damus.io")
      :ok
  """
  @spec disconnect(relay_name()) :: :ok | {:error, :not_found | String.t()}
  def disconnect(relay_name) when is_binary(relay_name) do
    # Try as direct relay name first, then as URL
    case Client.close_conn(relay_name) do
      :ok ->
        :ok

      {:error, :not_found} ->
        case url_to_relay_name(relay_name) do
          {:ok, name} -> Client.close_conn(name)
          {:error, _} -> {:error, :not_found}
        end

      error ->
        error
    end
  end

  @doc """
  List all connected relays.

  ## Examples

      iex> NostrEx.list_relays()
      ["relay.damus.io", "relay.nostr.band"]
  """
  @spec list_relays() :: [relay_name()]
  def list_relays, do: RelayManager.registered_names()

  @doc """
  Get detailed status of all connected relays.

  Returns a list of maps with url, name, ready?, and closing? fields.
  """
  @spec relay_states() :: [map()]
  def relay_states, do: RelayManager.get_states()

  # Events

  @doc """
  Create an unsigned event.

  ## Parameters
  - `kind` - Event kind (integer)
  - `attrs` - Event attributes as a map or keyword list

  ## Examples

      iex> NostrEx.create_event(1, content: "Hello!")
      {:ok, %Nostr.Event{kind: 1, content: "Hello!", ...}}

      iex> NostrEx.create_event(1, %{content: "Hello!"})
      {:ok, %Nostr.Event{kind: 1, content: "Hello!", ...}}
  """
  @spec create_event(integer(), map() | keyword()) :: {:ok, Event.t()} | {:error, String.t()}
  def create_event(kind, attrs) when is_integer(kind) and is_list(attrs) do
    if Keyword.keyword?(attrs) do
      event = Event.create(kind, attrs)
      {:ok, event}
    else
      {:error, "invalid attrs: must be a map or keyword list"}
    end
  end

  def create_event(kind, attrs) when is_integer(kind) and is_map(attrs) do
    list_attrs = Enum.into(attrs, [])
    create_event(kind, list_attrs)
  end

  def create_event(_kind, _attrs) do
    {:error, "invalid args: kind must be an integer, attrs must be a map or keyword list.}"}
  end

  @doc """
  Sign an event with a private key or signer process.

  ## Examples

      iex> {:ok, event} = NostrEx.create_event(1, content: "Hello!")
      iex> {:ok, signed} = NostrEx.sign_event(event, private_key)
      iex> signed.sig
      "abc123..."
  """
  @spec sign_event(Event.t(), binary() | pid()) :: {:ok, Event.t()} | {:error, String.t()}
  def sign_event(%Event{} = event, signer_or_privkey),
    do: Client.sign_event(event, signer_or_privkey)

  def sign_event(_event, _signer_or_privkey), do: {:error, "event must be an %Event{} struct"}

  @doc """
  Send a signed event to relays.

  The event must be signed before sending to prove the sender sent the message.

  Returns `{:ok, event_id, errors}` or `{:error, errors}`, since the event may be sent
  to multiple relays, and some sends may fail. `errors` is a list of errors in both returns.
  If it is an empty list `[]`, all sends succeeded.

  ## Options
  - `:send_via` - List of relay names or URLs. Defaults to all connected relays.

  ## Examples

      iex> {:ok, event} = NostrEx.create_event(1, content: "gm")
      iex> {:ok, signed} = NostrEx.sign_event(event, privkey)
      iex> NostrEx.send_event(signed)
      {:ok, "event_id_abc123...", []}

      iex> NostrEx.send_event(signed, send_via: [:relay_damus_io])
      {:ok, "event_id_abc123..."}
  """
  @spec send_event(Event.t(), keyword()) ::
          {:ok, event_id(), Keyword.t()} | {:error, String.t() | atom(), Keyword.t()}
  def send_event(event, opts \\ [])
  def send_event(%Event{sig: nil}, _opts), do: {:error, "event must be signed before sending"}
  def send_event(%Event{} = event, opts), do: Client.send_event(event, opts)

  # Subscriptions

  @doc """
  Create a subscription with filters.

  Returns a `%NostrEx.Subscription{}` struct that can be sent to relays.

  ## Examples

      # Single filter
      iex> NostrEx.create_sub(authors: ["abc123"], kinds: [1])
      {:ok, %NostrEx.Subscription{id: "...", filters: [...]}}

      # Multiple filters
      iex> NostrEx.create_sub([
      ...>   [authors: ["abc"], kinds: [1]],
      ...>   [kinds: [0, 3]]
      ...> ])
      {:ok, %NostrEx.Subscription{...}}
  """
  @spec create_sub(keyword() | [keyword()]) :: {:ok, Subscription.t()} | {:error, String.t()}
  def create_sub(filters), do: Subscription.new(filters)

  @doc """
  Send a subscription to relays.

  ## Options
  - `:send_via` - List of relay names or URLs. Defaults to all connected relays.

  ## Examples

      iex> {:ok, sub} = NostrEx.create_sub(authors: [pubkey], kinds: [1])
      iex> NostrEx.send_sub(sub)
      {:ok, "123zyx..."}

      iex> NostrEx.send_sub(sub, send_via: [:relay_damus_io])
      {:ok, "123zyx..."}
  """
  @spec send_sub(Subscription.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def send_sub(%Subscription{} = sub, opts \\ []), do: Client.send_sub(sub, opts)

  @doc """
  Close a subscription.

  Accepts a `%Subscription{}` struct or a subscription ID string.

  ## Examples

      iex> NostrEx.close_sub(sub)
      {:ok, [...], []}

      iex> NostrEx.close_sub("subscription_id_abc123")
      {:ok, [...], []}
  """
  @spec close_sub(Subscription.t() | sub_id()) ::
          {:ok, [String.t()], Keyword.t()} | {:error, String.t(), Keyword.t()}
  def close_sub(%Subscription{id: sub_id}), do: Client.close_sub(sub_id)
  def close_sub(sub_id) when is_binary(sub_id), do: Client.close_sub(sub_id)

  @doc """
  Register the current process to receive events for a subscription.

  After calling this, your process will receive messages of the form:
  - `{:event, sub_id, event}` - When an event matches the subscription
  - `{:eose, sub_id, relay_host}` - End of stored events from a relay

  Returns `:ok` if registration succeeds, or if already registered.

  ## Examples

      iex> {:ok, sub} = NostrEx.create_sub(kinds: [1])
      iex> :ok = NostrEx.send_sub(sub)
      iex> NostrEx.listen(sub)
      :ok
  """
  @spec listen(Subscription.t() | sub_id()) :: :ok
  def listen(%Subscription{id: sub_id}), do: do_listen(sub_id)
  def listen(sub_id) when is_binary(sub_id), do: do_listen(sub_id)

  defp do_listen(sub_id) do
    case Registry.register(NostrEx.PubSub, sub_id, []) do
      {:ok, _pid} -> :ok
      {:error, {:already_registered, _}} -> :ok
    end
  end

  @doc """
  List all active subscription IDs.

  ## Examples

      iex> NostrEx.list_subs()
      ["abc123...", "def456..."]
  """
  @spec list_subs() :: [sub_id()]
  def list_subs, do: RelayAgent.get_unique_subscriptions()

  @doc """
  Get which relays are handling a specific subscription.
  """
  @spec relays_for_sub(Subscription.t() | sub_id()) :: [relay_name()]
  def relays_for_sub(%Subscription{id: sub_id}), do: RelayAgent.get_relays_for_sub(sub_id)
  def relays_for_sub(sub_id) when is_binary(sub_id), do: RelayAgent.get_relays_for_sub(sub_id)

  @doc """
  Close all active subscriptions.
  """
  @spec close_all_subs() :: {:ok, [String.t()], Keyword.t()} | {:error, String.t(), Keyword.t()}
  def close_all_subs do
    results = Enum.map(list_subs(), &Client.close_sub/1)

    {closed, failed} =
      Enum.reduce(results, {[], []}, fn
        {:ok, relays, failures}, {c, f} -> {c ++ relays, f ++ failures}
        {:error, _reason, failures}, {c, f} -> {c, f ++ failures}
      end)

    case closed do
      [] -> {:error, "close failed", failed}
      _ -> {:ok, closed, failed}
    end
  end

  @spec url_to_relay_name(binary()) :: {:ok, relay_name()} | {:error, String.t()}
  defp url_to_relay_name(relay_url) do
    case URI.parse(relay_url) do
      %URI{host: nil} ->
        {:error, "Invalid URL: #{relay_url}"}

      %URI{host: host} ->
        relay_name = NostrEx.Utils.name_from_host(host)

        if relay_name in list_relays() do
          {:ok, relay_name}
        else
          {:error, "Relay not connected: #{relay_url}"}
        end
    end
  end
end
