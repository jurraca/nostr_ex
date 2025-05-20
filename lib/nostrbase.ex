defmodule Nostrbase do
  @moduledoc """
  The main module to use as a client. Connect to relays, send events and subscriptions, inspect and close connections etc.
  """

  alias Nostrbase.{Client, RelayAgent, RelayManager}

  @doc """
  Connect to a relay via its URL.
  """
  def add_relay(relay_url) do
    case RelayManager.connect(relay_url) do
      {:ok, _pid} = res -> res
      {:error, _} = err -> err
      _ -> {:error, "Couldn't add relay #{relay_url}"}
    end
  end

  @doc """
    Sends a text note via relays
    opts should include a :send_via key indicating relay_pids to send this note to. See get_relays/1.
  """
  def send_note(note, privkey, opts \\ []), do: Client.send_note(note, privkey, opts)

  def send_long_form(text, privkey, opts \\ []), do: Client.send_long_form(text, privkey, opts)

  @doc """
    Send a REQ message to a relay, by providing a keyword list of filter values, and optionally, relay conn PIDs with a `opts[:send_via]` list.
  """
  def send_subscription(filter, opts \\ []), do: Client.send_sub(filter, opts)

  @doc """
    Subscribe to a pubkey's notes, i.e. "follow" a pubkey.
  """
  def subscribe_pubkey(pubkey, opts \\ []) do
    send_subscription([authors: [pubkey], kinds: [1]], opts)
  end

  @doc """
    Get a pubkey's contact list.
  """
  def subscribe_contacts(pubkey, opts \\ []) do
    send_subscription([authors: [pubkey], kinds: [3]], opts)
  end

  @doc """
    Get a pubkey's profile data.
  """
  def subscribe_profile(pubkey, opts \\ []) do
    send_subscription([authors: [pubkey], kinds: [0]], opts)
  end

  def close_all_subs do
    for {pid, subs} <- RelayAgent.state() do
      Enum.map(subs, &Client.close_sub(pid, &1))
    end
  end

  def listen_for_sub(sub_id), do: Registry.register(Nostrbase.PubSub, sub_id, [])
end
