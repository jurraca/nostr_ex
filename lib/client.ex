defmodule Nostrbase.Client do
  @moduledoc """
    Wrap the Websocket Client in `WsClient`.
  """

  def send_event(relay_pid, text) when is_binary(text) do
    WebSockex.cast(relay_pid, {:send, {:text, text}})
  end

  def subscribe(relay_pid, sub_id, encoded_filter) do
    with {:ok, _pid} <- Registry.register(Nostrbase.PubSub, sub_id, []),
         :ok <- WebSockex.cast(relay_pid, {:send, {:text, encoded_filter, sub_id}}),
         :ok <- Nostrbase.RelayAgent.update(relay_pid, sub_id) do
      {:ok, sub_id}
    end
  end

  def close_sub(relay_pid, sub_id) do
    request = Nostrlib.CloseRequest.new(sub_id)
    send_event(relay_pid, request)
    Nostrbase.RelayAgent.delete(relay_pid, sub_id)
  end

  def close_conn(relay_pid) do
    DynamicSupervisor.terminate_child(RelayManager, relay_pid)
  end
end
