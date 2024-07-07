defmodule Nostrbase.WsClient do
  use WebSockex

  alias Nostrlib.Message
  alias Nostrbase.RelayAgent
  require Logger

  def start_link(relay_url) do
    WebSockex.start_link(relay_url, __MODULE__, %{relay_url: relay_url})
  end

  def handle_frame({:text, msg}, state) do
    msg
    |> Message.parse()
    |> handle_message(state)

    {:ok, state}
  end

  def handle_cast({:send, {type, msg} = frame}, state) do
    Logger.info("Sending #{type} frame with payload: #{msg}")
    {:reply, frame, state}
  end

  def handle_cast({:send, {type, msg, sub_id}}, state) do
    IO.puts("Sending #{sub_id} with frame: #{msg}")
    RelayAgent.update(self(), sub_id)
    {:reply, {type, msg}, state}
  end

  def handle_cast({:close, msg}, state) do
    {:reply, msg, state}
  end

  def handle_info(msg, state) do
    dbg(msg)
    {:ok, state}
  end

  defp handle_message({:event, subscription_id, event}, state) do
    Logger.info("received event for sub_id #{subscription_id}")

    subscription_id
    |> String.to_atom()
    |> registry_dispatch(event)

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
    subscription_id
    |> String.to_atom()
    |> registry_dispatch("EOSE")

    {:ok, state}
  end

  defp handle_message({:closed, sub_id, msg}, state) do
    Logger.info("Deleting subscription #{sub_id}: #{msg}")
    RelayAgent.delete(self(), sub_id)
    {:ok, state}
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

  def terminate({:remote, :closed}, state) do
    Logger.info("Remote closed the connection - #{state.relay_url}")
    RelayAgent.delete(self())
    {:ok, state}
  end

  def terminate(close_reason, state) do
    Logger.info(close_reason)
    RelayAgent.delete(self())
    {:ok, state}
  end

  @doc """
  Send a message to a given pubsub topic
  """
  def registry_dispatch(sub_id, message) when is_atom(sub_id) do
    Registry.dispatch(Nostrbase.PubSub, sub_id, fn entries ->
      for {pid, _} <- entries, do: send(pid, message)
    end)
  end
end
