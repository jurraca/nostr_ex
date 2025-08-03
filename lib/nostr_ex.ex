defmodule NostrEx do
  @moduledoc """
  A Nostr client library for Elixir applications.

  ## Quick Start

      # Connect to a relay (returns registered atom name)
      {:ok, relay_name} = NostrEx.connect_relay("wss://relay.example.com")
      # => {:ok, :relay_example_com}

      # Send a note
      NostrEx.send_note("Hello Nostr!", private_key)

      # Subscribe to a user's notes
      {:ok, sub_id} = NostrEx.subscribe_notes(pubkey)

      # Listen for events
      NostrEx.listen_for_subscription(sub_id)

  ## Modules

  - `NostrEx.Client` - Low-level client operations
  - `NostrEx.RelayManager` - Relay connection management
  - `NostrEx.Socket` - WebSocket connection handling
  - `NostrEx.Nip05` - NIP-05 verification utilities
  """

  alias NostrEx.{Client, RelayAgent, RelayManager}
  alias Nostr.Event

  # === Relay Management ===

  @doc """
  Connect to a relay via its URL.

  ## Examples

      iex> NostrEx.connect_relay("wss://relay.example.com")
      {:ok, :relay_example_com}

      iex> NostrEx.connect_relay("not-a-url")
      {:error, "Invalid URL"}
  """
  @spec connect_relay(binary()) :: {:ok, atom()} | {:error, String.t()}
  def connect_relay(relay_url), do: RelayManager.connect(relay_url)

  @doc """
  Disconnect from a relay. Closes the websocket connection and clears any associated subscription tracking data.
  The argument can either be the binary URL of the relay, or the relay's registered name.

  ## Examples

      iex> NostrEx.disconnect_relay("wss://relay.example.com")
      :ok

      iex> NostrEx.disconnect_relay(:relay_example_com)
      :ok
  """
  @spec disconnect_relay(binary() | atom()) :: :ok | {:error, :not_found}
  def disconnect_relay(relay_url) when is_binary(relay_url) do
    case url_to_relay_name(relay_url) do
      {:ok, relay_name} -> Client.close_conn(relay_name)
      {:error, reason} -> {:error, reason}
    end
  end

  def disconnect_relay(relay_name) when is_atom(relay_name), do: Client.close_conn(relay_name)

  # Helper function to convert URL to registered atom name
  @spec url_to_relay_name(binary()) :: {:ok, atom()} | {:error, String.t()}
  defp url_to_relay_name(relay_url) do
    case URI.parse(relay_url) do
      %URI{host: nil} -> {:error, "Invalid URL: #{relay_url}"}
      %URI{host: host} -> 
        relay_name = NostrEx.Utils.name_from_host(host)
        if relay_name in RelayManager.registered_names() do
          {:ok, relay_name}
        else
          {:error, "Relay not connected: #{relay_url}"}
        end
    end
  end

  @doc """
  Get the status of all connected relays.

  Returns a list of relay status maps containing url, name, ready?, and closing? fields.
  """
  def list_relay_states, do: RelayManager.get_states()

  @doc """
  Get list of connected relay names.
  """
  def list_connected_relays, do: RelayManager.registered_names()

  @doc """
  Create event from `attrs`.

  `attrs` can be a map with atom keys or a keyword list.
  """
  def create_event(kind, %{} = attrs) do
    Event.create(kind, Enum.into(attrs, []))
  end

  def create_event(kind, attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs) do
      Event.create(kind, attrs)
    else
      {:error, "invalid attrs: must be a map or Keyword list with a `:kind` attribute"}
    end
  end

  def create_event(_), do: {:error, "invalid attrs provided, must be a map or a keyword list"}

  @doc """
  Sign an event with a signer or private key.
  """
  def sign_event(%Event{} = event, signer_or_privkey), do: Client.sign_event(event, signer_or_privkey)

  def sign_event(_event, _signer_or_privkey), do: {:error, "event must be an %Event{} struct"}

  # === Publishing Events ===

  @doc """
  Send a text note (kind 1) via relays.

  ## Options

  - `:send_via` - List of relay names to send this note to. Defaults to all connected relays.

  ## Examples

      iex> NostrEx.send_note("Hello Nostr!", private_key)
      {:ok, "abcd1231f..."}

      iex> signer = NostrEx.Signer.PrivateKey.new(private_key)
      iex> NostrEx.send_note("Hello Nostr!", signer)
      {:ok, "abcd1231f..."}

      iex> NostrEx.send_note("Hello specific relay!", private_key, send_via: ["relay_example_com"])
      {:ok, "abcd1231f..."}
  """
  @spec send_note(binary(), binary() | struct(), Keyword.t()) ::
          {:ok, :sent} | {:error, String.t()}
  def send_note(note, signer_or_privkey, opts \\ []) do
    case is_binary(note) do
      true ->
        %{event: event} = Event.Note.create(note)
        Client.sign_and_send_event(event, signer_or_privkey, opts)

      false ->
        {:error, "Note must be a binary, got: #{note}"}
    end
  end

  @doc """
  Send a long-form note (kind 30023) via relays.

  ## Options

  - `:send_via` - List of relay names to send this note to. Defaults to all connected relays.

  ## Examples

      iex> NostrEx.send_long_form("# My Blog Post\\n\\nContent here...", private_key)
      {:ok, :sent}

      iex> signer = NostrEx.Signer.PrivateKey.new(private_key)
      iex> NostrEx.send_long_form("# My Blog Post\\n\\nContent here...", signer)
      {:ok, :sent}
  """
  @spec send_long_form(binary(), binary() | struct(), Keyword.t()) ::
          {:ok, :sent} | {:error, String.t()}
  def send_long_form(text, signer_or_privkey, opts \\ []) do
    case is_binary(text) do
      true ->
        event = Event.create(30023, content: text)
        Client.sign_and_send_event(event, signer_or_privkey, opts)

      false ->
        {:error, "Note must be a binary, got: #{text}"}
    end
  end

  @doc """
  Send an event.

  ## Options

  - `:send_via` - List of relay names to send this note to. Defaults to all connected relays.

  ## Examples

      iex> NostrEx.send_event(%Event{kind: 1, content: "gm"}, send_via: ["wss://relay.lol"])
      {:ok, :sent}
  """
  @spec send_event(map(), Keyword.t()) :: {:ok, :sent} | {:error, String.t()}
  def send_event(%Event{} = event, opts \\ []) do
    Client.send_event(event, opts)
  end

  # === Subscriptions ===

  @doc """
  Send a REQ message to relays with custom filters.

  ## Options

  - `:send_via` - List of relay names to send this subscription to. Defaults to all connected relays.

  ## Examples

      iex> NostrEx.send_subscription([authors: [pubkey], kinds: [1]], send_via: ["relay_example_com"])
      {:ok, "subscription_id"}
  """
  @spec send_subscription([Keyword.t()] | Keyword.t(), Keyword.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def send_subscription(filter, opts \\ []), do: Client.send_sub(filter, opts)

  @doc """
  Subscribe to a pubkey's notes (kind 1).

  ## Examples

      iex> NostrEx.subscribe_notes(pubkey)
      {:ok, "subscription_id"}
  """
  @spec subscribe_notes(binary(), Keyword.t()) :: {:ok, String.t()} | {:error, String.t()}
  def subscribe_notes(pubkey, opts \\ []) do
    send_subscription([authors: [pubkey], kinds: [1]], opts)
  end

  @doc """
  Subscribe to a pubkey's contact list (kind 3).

  ## Examples

      iex> NostrEx.subscribe_follows(pubkey)
      {:ok, "subscription_id"}
  """
  @spec subscribe_follows(binary(), Keyword.t()) :: {:ok, String.t()} | {:error, String.t()}
  def subscribe_follows(pubkey, opts \\ []) do
    send_subscription([authors: [pubkey], kinds: [3]], opts)
  end

  @doc """
  Subscribe to a pubkey's profile metadata (kind 0).

  ## Examples

      iex> NostrEx.subscribe_profile(pubkey)
      {:ok, "subscription_id"}
  """
  @spec subscribe_profile(binary(), Keyword.t()) :: {:ok, String.t()} | {:error, String.t()}
  def subscribe_profile(pubkey, opts \\ []) do
    send_subscription([authors: [pubkey], kinds: [0]], opts)
  end

  @doc """
  Close a specific subscription by ID.

  ## Examples

      iex> NostrEx.close_subscription("subscription_id")
      {:ok, :closed}
  """
  @spec close_subscription(binary()) :: {:ok, String.t()} | {:error, String.t()}
  def close_subscription(sub_id), do: Client.close_sub(sub_id)

  @doc """
  Close all active subscriptions.

  ## Examples

      iex> NostrEx.close_all_subscriptions()
      [ok: :closed, ok: :closed]
  """
  @spec close_all_subscriptions() :: [{:ok, String.t()} | {:error, String.t()}]
  def close_all_subscriptions do
    RelayAgent.get_unique_subscriptions()
    |> Enum.map(&Client.close_sub(&1))
  end

  @doc """
  Register the current process to receive messages for a subscription.

  After calling this function, your process will receive messages like:
  - `{:event, subscription_id, event}` - When an event matches the subscription
  - `{:eose, subscription_id, relay_host}` - When a relay sends "end of stored events"

  ## Examples

      iex> {:ok, sub_id} = NostrEx.subscribe_notes(pubkey)
      iex> NostrEx.listen_for_subscription(sub_id)
      :ok
  """
  @spec listen_for_subscription(binary()) :: :ok
  def listen_for_subscription(sub_id), do: Registry.register(NostrEx.PubSub, sub_id, [])

  # === Utility Functions ===

  @doc """
  Get all active subscription IDs.
  """
  @spec list_active_subscriptions() :: [String.t()]
  def list_active_subscriptions, do: RelayAgent.get_unique_subscriptions()

  @doc """
  Get which relays are handling a specific subscription.
  """
  @spec list_subscription_relays(binary()) :: [atom()]
  def list_subscription_relays(sub_id), do: RelayAgent.get_relays_for_sub(sub_id)
end
