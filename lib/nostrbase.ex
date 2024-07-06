defmodule Nostrbase do
  @moduledoc """
  The main module to use as a client. Connect to relays, send events and subscriptions, inspect and close connections etc.
  """

  alias Nostrbase.{Client, RelayManager}
  alias Nostrlib.{Filter, Note}

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
  def send_note(note, privkey, opts \\ []) do
    with {:ok, relay_pids} <- get_relays(opts),
          {:ok, json_event} <- Note.to_event_serialized(note, privkey) do
          Enum.each(relay_pids, &Client.send_event(&1, json_event))
      else
        {:error, reason} -> {:error, reason}
        _ -> {:error, "Invalid event submitted for note \"#{note}\" "}
    end
  end

  @doc """
    Send a REQ message to a relay, by providing a json-encoded filter, a subscription ID, and optionally, relay conn PIDs with a `opts[:send_via]` list.
  """
  def send_subscription(sub_id, filter, opts \\ []) when is_binary(filter) do
      with {:ok, relay_pids} <- get_relays(opts) do
          Enum.each(relay_pids, &Client.subscribe(&1, sub_id, filter))
      else
          {:error, reason} -> {:error, reason}
      end
  end

  @doc """
    Subscribe to a pubkey's notes, i.e. "follow" a pubkey.
  """
  def subscribe_to_pubkey(pubkey) do
     with {:ok, filter} <- Filter.notes([pubkey]),
          sub_id <- Filter.create_sub_id(),
         {:ok, req_string} <- Filter.encode(sub_id, filter) do
         send_subscription(sub_id, req_string)
     end
  end

  @doc """
    Get a pubkey's contact list.
  """
  def get_contacts(pubkey) do
     with {:ok, filter} <- Filter.contacts(pubkey),
          {:ok, req} <- Filter.create_sub_id() |> Filter.encode(filter) do
       send_subscription("", req)
     end
  end

  def listen_for_subs(sub_id, pubsub), do: Registry.register(pubsub, sub_id, [])

  defp get_relays(nil), do: {:error, :empty_opts}
  defp get_relays(:all), do: {:ok, RelayManager.active_pids()}

  defp get_relays([_h | _t] = relay_list) do
    case Enum.all?(relay_list, &is_pid(&1)) do
       false -> {:error, "One or more relay PIDs were invalid, got: #{relay_list}"}
       true -> {:ok, relay_list}
    end
  end

  defp get_relays(relay_list), do: {:error, "invalid relay list provided, got: #{relay_list}"}
end
