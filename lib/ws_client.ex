defmodule Nostrbase.WsClient do
  use WebSockex

  alias Nostrlib.Message
  require Logger

  def start_link(relay_url) do
     WebSockex.start_link(relay_url, __MODULE__, %{relay_url: relay_url})
  end

  def handle_frame({:text, msg}, state) do
    IO.puts "Received a message: #{msg}"
    
    msg
    |> Message.parse()
    |> handle_message(state)

    {:ok, state}
  end

  def handle_cast({:send, {type, msg} = frame}, state) do
    IO.puts "Sending #{type} frame with payload: #{msg}"
    dbg(state)
    {:reply, frame, state}
  end

  def handle_cast({:send, {type, msg, sub_id} = frame}, state) do
    IO.puts "Sending #{type} frame with payload: #{msg}"
    IO.inspect(state)
    {:reply, frame, state}
  end
  
  defp handle_message({:event, subscription_id, _} = message, state) do
    Logger.info("received event for sub_id #{subscription_id}")

    subscription_id
    |> String.to_atom()
    |> registry_dispatch(message)

    {:ok, state}
  end

  defp handle_message({:notice, message}, state) do
    Logger.info("NOTICE from #{state.relay_url}: #{message}")
    registry_dispatch(:notice, message)
    {:ok, state}
  end

  defp handle_message(
         {:end_of_stored_events, subscription_id},
          state
       ) do
    message = {:end_of_stored_events, subscription_id}

    subscription_id
    |> String.to_atom()
    |> registry_dispatch(message)

    {:ok, state}
  end

  defp handle_message({:closed, sub_id, msg}, %{subscriptions: subs} = state) do
    Logger.info("Deleting subscription #{sub_id}: #{msg}")
    new_subscriptions = List.delete(subs, String.to_atom(sub_id))
    {:ok, %{state | subscriptions: new_subscriptions}}
  end

  
  defp handle_message({:ok, event_id, message}, state) do
    Logger.info("OK event #{event_id} from #{state.relay_url}")
    # GenServer.reply(from, {:ok, event_id, message})
    registry_dispatch(:ok, message)
    {:ok, state}
  end

  defp handle_message({:error, event_id, message}, state) do
    Logger.error(event_id <> ": " <> message)
    registry_dispatch(:error, message)
    {:ok, state}
  end

  defp handle_message({:unknown, message}, state) do
    Logger.info(message)
    registry_dispatch(:error, "#{message} from #{state.relay_url}")
    {:ok, state}
  end

  defp handle_message({:json_error, message}, state) do
    Logger.error(message)
    {:ok, state}
  end

  def terminate(close_reason, state) do
    Logger.info(close_reason)
    {:ok, state}
  end

  @doc """
  Send a message to a given pubsub topic
  """
  def registry_dispatch(sub_id, message) when is_atom(sub_id) do
    Registry.dispatch(Registry.PubSub, sub_id, fn entries ->
      for {pid, _} <- entries, do: send(pid, message)
    end)
  end
end
