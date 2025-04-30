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

  def send_event(relay_pid, payload) when is_binary(payload) do
    Socket.send_message(relay_pid, payload)
  end

  def send_sub(filter, opts \\ []), do: do_subscribe_send(filter, opts)

  def close_sub(relay_pid, sub_id) when is_binary(sub_id) do
    close_sub(relay_pid, String.to_existing_atom(sub_id))
  end

  def close_sub(relay_pid, sub_id) do
    request = Nostr.Message.close(sub_id)
    send_event(relay_pid, request)
    RelayAgent.delete_subscription(relay_pid, sub_id)
  end

  def close_conn(relay_pid) do
    # close all subs for that relay, then terminate
    DynamicSupervisor.terminate_child(RelayManager, relay_pid)
  end

  def create_note(note, privkey) do
      note
      |> Event.Note.create()
      |> Event.sign(privkey)
      |> Message.create_event()
      |> Message.serialize()
  end

  def create_long_form(text, privkey) do
    Event.create(23, [content: text])
    |> Event.sign(privkey)
    |> Message.create_event()
    |> Message.serialize()
  end

  def create_sub(opts) when is_list(opts) do
     with filter <- Map.merge(%Filter{}, Enum.into(opts, %{})),
       sub_id <- :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower) do
       msg = [filter]
        |> Message.request(sub_id)
        |> Message.serialize()

       {:ok, sub_id, msg}
     end
  end

  def subscribe(relay_pid, sub_id, payload) when is_binary(sub_id) do
    subscribe(relay_pid, String.to_atom(sub_id), payload)
  end

  def subscribe(relay_pid, sub_id, payload) when is_atom(sub_id) do
    with {:ok, _pid} <- Registry.register(Nostrbase.PubSub, sub_id, []),
         :ok <- send_event(relay_pid, payload),
         :ok <- Nostrbase.RelayAgent.update(relay_pid, sub_id) do
      {:ok, sub_id}
    end
  end

  defp do_event_send(privkey, arg, create_fun, opts) do
    with {:ok, relay_pids} <- get_relays(opts[:send_via]),
         json_event <- create_fun.(arg, privkey) do
      Enum.each(relay_pids, &send_event(&1, json_event))
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, "Invalid event submitted with argument \"#{arg}\" "}
    end
  end

  defp do_subscribe_send(filter, opts) do
    with {:ok, relay_pids} <- get_relays(opts[:send_via]),
         {:ok, sub_id, message} <- create_sub(filter) do
      # validate all responses and collect errors
      Enum.each(relay_pids, &subscribe(&1, sub_id, message))
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_relays(nil), do: get_relays(:all)
  defp get_relays(:all), do: {:ok, RelayManager.active_pids()}

  defp get_relays([_h | _t] = relay_list) do
    case Enum.all?(relay_list, &is_pid(&1)) do
      false -> {:error, "One or more relay PIDs provided were invalid."}
      true -> {:ok, relay_list}
    end
  end

  defp get_relays(relay_list), do: {:error, "invalid relay list provided, got: #{relay_list}"}
end
