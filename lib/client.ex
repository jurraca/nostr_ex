defmodule Nostrbase.Client do
  @moduledoc """
    Wrap the Websocket Client in `WsClient`.
  """

  def send_event(relay_pid, text) when is_binary(text) do
    WebSockex.cast(relay_pid, {:send, {:text, text}})
  end

  def subscribe(relay_pid, sub_id, encoded_filter) do
    WebSockex.cast(relay_pid, {:send, {:text, encoded_filter, sub_id}})
  end

  def close(relay_pid, sub_id) do
     request = Nostrlib.CloseRequest.new(sub_id)
     send_event(relay_pid, request)
  end
end
