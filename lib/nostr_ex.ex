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

  # === Relay Management ===

  @doc """
  Connect to a relay via its URL.

  ## Examples

      iex> NostrEx.add_relay("wss://relay.example.com")
      {:ok, #PID<0.123.0>}

      iex> NostrEx.add_relay("invalid-url")
      {:error, "Invalid URL"}
  """
  def add_relay(relay_url) do
    case RelayManager.connect(relay_url) do
      {:ok, _pid} = res -> res
      {:error, _} = err -> err
      _ -> {:error, "Couldn't add relay #{relay_url}"}
    end
  end

  @doc """
  Remove a relay connection.

  ## Examples

      iex> NostrEx.remove_relay("wss://relay.example.com")
      :ok
  """
  def remove_relay(relay_url) when is_binary(relay_url) do
    relay_url
    |> URI.parse()
    |> Map.get(:host)
    |> NostrEx.Utils.name_from_host()
    |> Client.close_conn()
  end

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
  def send_note(note, privkey, opts \\ []), do: Client.send_note(note, privkey, opts)

  @doc """
  Send a long-form note (kind 30023) via relays.

  ## Options

  - `:send_via` - List of relay names to send this note to. Defaults to all connected relays.

  ## Examples

      iex> NostrEx.send_long_form("# My Blog Post\\n\\nContent here...", private_key)
      {:ok, :sent}
  """
  def send_long_form(text, privkey, opts \\ []), do: Client.send_long_form(text, privkey, opts)

  # === Subscriptions ===

  @doc """
  Send a REQ message to relays with custom filters.

  ## Options

  - `:send_via` - List of relay names to send this subscription to. Defaults to all connected relays.

  ## Examples

      iex> NostrEx.send_subscription([authors: [pubkey], kinds: [1]], send_via: ["relay_example_com"])
      {:ok, "subscription_id"}
  """
  def send_subscription(filter, opts \\ []), do: Client.send_sub(filter, opts)

  @doc """
  Subscribe to a pubkey's notes (kind 1).

  ## Examples

      iex> NostrEx.subscribe_notes(pubkey)
      {:ok, "subscription_id"}
  """
  def subscribe_notes(pubkey, opts \\ []) do
    send_subscription([authors: [pubkey], kinds: [1]], opts)
  end

  @doc """
  Subscribe to a pubkey's contact list (kind 3).

  ## Examples

      iex> NostrEx.subscribe_follows(pubkey)
      {:ok, "subscription_id"}
  """
  def subscribe_follows(pubkey, opts \\ []) do
    send_subscription([authors: [pubkey], kinds: [3]], opts)
  end

  @doc """
  Subscribe to a pubkey's profile metadata (kind 0).

  ## Examples

      iex> NostrEx.subscribe_profile(pubkey)
      {:ok, "subscription_id"}
  """
  def subscribe_profile(pubkey, opts \\ []) do
    send_subscription([authors: [pubkey], kinds: [0]], opts)
  end

  @doc """
  Close a specific subscription by ID.

  ## Examples

      iex> NostrEx.close_subscription("subscription_id")
      {:ok, :closed}
  """
  def close_subscription(sub_id), do: Client.close_sub(sub_id)

  @doc """
  Close all active subscriptions.

  ## Examples

      iex> NostrEx.close_all_subscriptions()
      [ok: :closed, ok: :closed]
  """
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
  def listen_for_subscription(sub_id), do: Registry.register(NostrEx.PubSub, sub_id, [])

  # === Utility Functions ===

  @doc """
  Get all active subscription IDs.
  """
  def active_subscriptions, do: RelayAgent.get_unique_subscriptions()

  @doc """
  Get which relays are handling a specific subscription.
  """
  def subscription_relays(sub_id), do: RelayAgent.get_relays_for_sub(sub_id)
end
