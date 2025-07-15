defmodule NostrEx do
  @moduledoc """
  A lightweight, OTP-compliant Nostr client library for Elixir applications.

  ## Quick Start

      # Connect to a relay
      {:ok, _pid} = NostrEx.add_relay("wss://relay.example.com")

      # Send a note
      NostrEx.send_note("Hello Nostr!", private_key)

      # Subscribe to a user's notes
      {:ok, sub_id} = NostrEx.subscribe_notes(pubkey)

      # Listen for events
      NostrEx.listen_for_sub(sub_id)

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

      iex> NostrEx.add_relay("wss://relay.example.com")
      {:ok, #PID<0.123.0>}

      iex> NostrEx.add_relay("invalid-url")
      {:error, "Invalid URL"}
  """
  @spec add_relay(binary()) :: {:ok, pid()} | {:error, String.t() | term()}
  def add_relay(relay_url) do
    RelayManager.connect(relay_url)
  end

  @doc """
  Remove a relay connection.

  ## Examples

      iex> NostrEx.remove_relay("wss://relay.example.com")
      :ok

      iex> NostrEx.remove_relay(:relay_example_com)
      :ok
  """
  @spec remove_relay(binary()) :: :ok | {:error, :not_found}
  def remove_relay(relay_url) when is_binary(relay_url) do
    relay_url
    |> URI.parse()
    |> Map.get(:host)
    |> NostrEx.Utils.name_from_host()
    |> Client.close_conn()
  end

  def remove_relay(relay_url) when is_atom(relay_url), do: Client.close_conn(relay_url)

  @doc """
  Get the status of all connected relays.

  Returns a list of relay status maps containing url, name, ready?, and closing? fields.
  """
  def relay_status, do: RelayManager.get_states()

  @doc """
  Get list of connected relay names.
  """
  def connected_relays, do: RelayManager.registered_names()

  # === Publishing Events ===

  @doc """
  Send a text note (kind 1) via relays.

  ## Options

  - `:send_via` - List of relay names to send this note to. Defaults to all connected relays.

  ## Examples

      iex> NostrEx.send_note("Hello Nostr!", private_key)
      {:ok, :sent}

      iex> NostrEx.send_note("Hello specific relay!", private_key, send_via: ["relay_example_com"])
      {:ok, :sent}
  """
  @spec send_note(binary(), binary(), Keyword.t()) :: {:ok, :sent} | {:error, String.t()}
  def send_note(note, privkey, opts \\ []) do
    case is_binary(note) do
      true ->
        %{event: event} = Event.Note.create(note)
        Client.send_event(event, privkey, opts)

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
  """
  @spec send_note(binary(), binary(), Keyword.t()) :: {:ok, :sent} | {:error, String.t()}
  def send_long_form(text, privkey, opts \\ []) do
    case is_binary(text) do
      true ->
        event = Event.create(30023, content: text)
        send_event(event, privkey, opts)

      false ->
        {:error, "Note must be a binary, got: #{text}"}
    end
  end

  @doc """
  Send an event.
  
  ## Options

  - `:send_via` - List of relay names to send this note to. Defaults to all connected relays.
  
  ## Examples

      iex> NostrEx.send_event(%Event{kind: 1, content: "gm"}, privkey)
      {:ok, :sent}
  """
  @spec send_event(Event.t(), binary(), Keyword.t()) :: {:ok, :sent} | {:error, String.t()}
  def send_event(%Nostr.Event{} = event, privkey, opts \\ []) do
    Client.send_event(event, privkey, opts)
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
  @spec send_subscription(List.t() | Keyword.t(), Keyword.t()) :: {:ok, String.t()} | {:error, String.t()}
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
  @spec active_subscriptions() :: [String.t()]
  def active_subscriptions, do: RelayAgent.get_unique_subscriptions()

  @doc """
  Get which relays are handling a specific subscription.
  """
  @spec subscription_relays(binary()) :: [atom()]
  def subscription_relays(sub_id), do: RelayAgent.get_relays_for_sub(sub_id)
end
