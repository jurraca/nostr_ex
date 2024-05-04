defmodule Nostrbase do
  @moduledoc """
  Documentation for `Nostrbase`.
  """
  
  alias Nostrbase.RelayManager
  alias Nostrlib.Note

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
  """
  @spec send_note(String.t(), PrivateKey.id()) :: :ok | {:error, String.t()}
  def send_note(note, privkey) do
    relay_pids = RelayManager.active_pids()
    send_note(note, privkey, relay_pids)
  end

  def send_note(note, privkey, relay_pids) do
    case Note.create_serialized(note, privkey) do
        {:ok, json_event} -> Enum.each(relay_pids, &send_event(&1, json_event))
        _ -> {:error, "Invalid event submitted for note \"#{note}\" "}
    end
  end

  @doc """
  Send JSON-encoded Nostr events.
  """
  def send_event(pid, text) when is_binary(text) do
    WebSockex.cast(pid, {:send, {:text, text}})
  end

  def subscribe(relay_pid, sub_id, encoded_filter) do
    WebSockex.cast(relay_pid, {:send, {:text, encoded_filter, sub_id}})
  end
end
