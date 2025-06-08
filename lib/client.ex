defmodule Nostrbase.Client do
  @moduledoc """
    Wrap the Websocket Client in `WsClient`.
  """

  alias Nostr.{Event, Filter, Message}
  alias Nostrbase.{RelayAgent, RelayManager, Socket, Utils}

  def send_note(note, privkey, opts \\ []) do
    do_event_send(privkey, note, &create_note/2, opts)
  end

  def send_long_form(text, privkey, opts \\ []) do
    do_event_send(privkey, text, &create_long_form/2, opts)
  end

  def send_event(relay_name, payload) when is_binary(payload) do
    Socket.send_message(relay_name, payload)
  end

  def send_sub(filter, opts \\ []) do
    with {:ok, sub_id, message} <- create_sub(filter),
         {:ok, _pid} <- Registry.register(Nostrbase.PubSub, sub_id, nil) do
      opts[:send_via]
      |> get_relays()
      |> Enum.each(fn relay_name ->
        subscribe(relay_name, sub_id, message)
      end)

      {:ok, sub_id}
    else
      {:error, reason} -> {:error, reason}
    end
  end

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
        opts
        |> Enum.map(&Map.merge(%Filter{}, Enum.into(&1, %{})))
        |> do_create_sub()

      true ->
        {:error, "Invalid filter format"}
    end
  end

  def subscribe(relay_name, sub_id, payload) when is_binary(sub_id) do
    with :ok <- send_event(relay_name, payload),
         :ok <- RelayAgent.update(relay_name, sub_id) do
      :ok
    end
  end

  def subscribe(_, sub_id, _), do: {:error, "invalid sub_id format, got #{sub_id}"}

  defp do_event_send(privkey, arg, create_fun, opts) do
    with relay_names = get_relays(opts[:send_via]),
         json_event <- create_fun.(arg, privkey) do
      results = Enum.map(relay_names, &send_event(&1, json_event))

      case Enum.all?(results, &(&1 == :ok)) do
        true -> {:ok, :sent}
        false -> {:error, Enum.filter(results, &match?({:error, _}, &1))}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, "Invalid event submitted with argument \"#{arg}\" "}
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

  defp get_relays(nil), do: get_relays(:all)
  defp get_relays(:all), do: RelayManager.registered_names()

  defp get_relays([_h | _t] = relay_list) do
    Enum.map(relay_list, fn relay ->
      case URI.parse(relay) do
        %{host: host} -> RelayManager.name_from_host(host)
        _ -> relay
      end
    end)
  end

  defp get_relays(relay_list), do: {:error, "invalid relay list provided, got: #{relay_list}"}
end
