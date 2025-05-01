defmodule Nostrbase.Client do
  @moduledoc """
    Wrap the Websocket Client in `WsClient`.
  """

  alias Nostr.{Event, Filter, Message}
  alias Nostrbase.{RelayAgent, RelayManager, Socket}

  def send_note(note, privkey, opts \\ []) do
    do_event_send(privkey, note, &create_note/2, opts)
  end

  def send_long_form(text, privkey, opts \\ []) do
    do_event_send(privkey, text, &create_long_form/2, opts)
  end

  def send_event(relay_name, payload) when is_binary(payload) do
    case Registry.lookup(Nostrbase.RelayRegistry, relay_name) do
      [{pid, _}] -> Socket.send_message(pid, payload)
      _ -> {:error, :not_found}
    end
  end

  def send_sub(filter, opts \\ []), do: do_subscribe_send(filter, opts)

  def close_sub(relay_name, sub_id) when is_binary(sub_id) do
    close_sub(relay_name, String.to_existing_atom(sub_id))
  end

  def close_sub(relay_name, sub_id) do
    request = Message.close(sub_id) |> Message.serialize()
    case send_event(relay_name, request) do
      {:ok, _} -> RelayAgent.delete_subscription(relay_name, sub_id)
      err -> err
    end
  end

  def close_conn(relay_name) do
    case Registry.lookup(Nostrbase.RelayRegistry, relay_name) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(RelayManager, pid)
      _ -> {:error, :not_found}
    end
  end

  def create_note(note, privkey) do
    note
    |> Event.Note.create()
    |> Event.sign(privkey)
    |> Message.create_event()
    |> Message.serialize()
  end

  def create_long_form(text, privkey) do
    Event.create(23, content: text)
    |> Event.sign(privkey)
    |> Message.create_event()
    |> Message.serialize()
  end

  def create_sub(opts) when is_list(opts) do
    cond do
      # Single filter as keyword list
      Keyword.keyword?(opts) ->
        filter = Map.merge(%Filter{}, Enum.into(opts, %{}))
        do_create_sub([filter])
        
      # Multiple filters as list of keyword lists
      Enum.all?(opts, &Keyword.keyword?/1) ->
        filters = Enum.map(opts, &Map.merge(%Filter{}, Enum.into(&1, %{})))
        do_create_sub(filters)
        
      true ->
        {:error, "Invalid filter format"}
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

  def subscribe(relay_name, sub_id, payload) when is_binary(sub_id) do
    subscribe(relay_name, String.to_atom(sub_id), payload)
  end

  def subscribe(relay_name, sub_id, payload) when is_atom(sub_id) do
    with {:ok, _pid} <- Registry.register(Nostrbase.PubSub, sub_id, []),
         :ok <- send_event(relay_name, payload),
         :ok <- Nostrbase.RelayAgent.update(relay_name, sub_id) do
      {:ok, sub_id}
    end
  end

  defp do_event_send(privkey, arg, create_fun, opts) do
    with {:ok, relay_names} <- get_relays(opts[:send_via]),
         json_event <- create_fun.(arg, privkey) do
      Enum.each(relay_names, &send_event(&1, json_event))
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, "Invalid event submitted with argument \"#{arg}\" "}
    end
  end

  defp do_subscribe_send(filter, opts) do
    with {:ok, relay_names} <- get_relays(opts[:send_via]),
         {:ok, sub_id, message} <- create_sub(filter) do
      # validate all responses and collect errors
      Enum.each(relay_names, &subscribe(&1, sub_id, message))
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_relays(nil), do: get_relays(:all)
  defp get_relays(:all), do: {:ok, RelayManager.active_names()}

  defp get_relays([_h | _t] = relay_list) do
    case Enum.all?(relay_list, &is_binary(&1)) do
      false -> {:error, "One or more relay names provided were invalid."}
      true -> {:ok, relay_list}
    end
  end

  defp get_relays(relay_list), do: {:error, "invalid relay list provided, got: #{relay_list}"}
end
