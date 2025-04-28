defmodule Nostrbase.Socket do
  use GenServer

  require Logger
  require Mint.HTTP

  alias Nostrbase.RelayAgent
  alias Nostr.Message

  defstruct [:url, :conn, :websocket, :request_ref, :caller, :status, :resp_headers, :closing?]

  def start_link(%{url: url}) do
    GenServer.start_link(__MODULE__, url)
  end

  def connect(url) do
    GenServer.call(__MODULE__, {:connect, url})
  end

  def send_message(pid, text) do
    GenServer.call(pid, {:send_text, text})
  end

  @impl GenServer
  def init(url) do
    {:ok, %__MODULE__{url: url}, {:continue, :connect}}
  end

  @impl GenServer
  def handle_call({:send_text, text}, _from, state) do
    {:ok, state} = send_frame(state, {:text, text})
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_continue(:connect, %{url: url} = state) do
    uri = URI.parse(url)

    http_scheme =
      case uri.scheme do
        "ws" -> :http
        "wss" -> :https
      end

    ws_scheme =
      case uri.scheme do
        "ws" -> :ws
        "wss" -> :wss
      end

    path = uri.path || "/"

    with {:ok, conn} <- Mint.HTTP.connect(http_scheme, uri.host, uri.port),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(ws_scheme, conn, path, []) do
      state = %{state | conn: conn, request_ref: ref}
      {:noreply, state}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      {:error, conn, reason} ->
        {:reply, {:error, reason}, put_in(state.conn, conn)}
    end
  end

  @impl GenServer
  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        state = put_in(state.conn, conn) |> handle_responses(responses)
        if state.closing?, do: do_close(state), else: {:noreply, state}

      {:error, conn, reason, _responses} ->
        state = put_in(state.conn, conn) |> reply({:error, reason})
        {:noreply, state}

      :unknown ->
        {:noreply, state}
    end
  end

  defp handle_responses(state, responses)

  defp handle_responses(%{request_ref: ref} = state, [{:status, ref, status} | rest]) do
    put_in(state.status, status)
    |> handle_responses(rest)
  end

  defp handle_responses(%{request_ref: ref} = state, [{:headers, ref, resp_headers} | rest]) do
    put_in(state.resp_headers, resp_headers)
    |> handle_responses(rest)
  end

  defp handle_responses(%{request_ref: ref} = state, [{:done, ref} | rest]) do
    case Mint.WebSocket.new(state.conn, ref, state.status, state.resp_headers) do
      {:ok, conn, websocket} ->
        %{state | conn: conn, websocket: websocket, status: nil, resp_headers: nil}
        |> reply({:ok, :connected})
        |> handle_responses(rest)

      {:error, conn, reason} ->
        put_in(state.conn, conn)
        |> reply({:error, reason})
    end
  end

  defp handle_responses(%{request_ref: ref, websocket: websocket} = state, [
         {:data, ref, data} | rest
       ])
       when websocket != nil do
    case Mint.WebSocket.decode(websocket, data) do
      {:ok, websocket, frames} ->
        put_in(state.websocket, websocket)
        |> handle_frames(frames)
        |> handle_responses(rest)

      {:error, websocket, reason} ->
        put_in(state.websocket, websocket)
        |> reply({:error, reason})
    end
  end

  defp handle_responses(state, [_response | rest]) do
    handle_responses(state, rest)
  end

  defp handle_responses(state, []), do: state

  defp send_frame(state, frame) do
    with {:ok, websocket, data} <- Mint.WebSocket.encode(state.websocket, frame),
         state = put_in(state.websocket, websocket),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.request_ref, data) do
      {:ok, put_in(state.conn, conn)}
    else
      {:error, %Mint.WebSocket{} = websocket, reason} ->
        {:error, put_in(state.websocket, websocket), reason}

      {:error, conn, reason} ->
        {:error, put_in(state.conn, conn), reason}
    end
  end

  def handle_frames(state, frames) do
    Enum.reduce(frames, state, fn
      # reply to pings with pongs
      {:ping, data}, state ->
        {:ok, state} = send_frame(state, {:pong, data})
        state

      {:close, _code, reason}, state ->
        Logger.debug("Closing connection: #{inspect(reason)}")
        %{state | closing?: true}

      {:text, text}, state ->
        Logger.debug("Received: #{inspect(text)}")

        text
          |> Message.parse()
          |> handle_message(state)

        state

      frame, state ->
        Logger.debug("Unexpected frame received: #{inspect(frame)}")
        state
    end)
  end

  defp handle_message({:event, subscription_id, event}, state) do
    Logger.info("received event for sub_id #{subscription_id}")
    registry_dispatch(subscription_id, event)
    {:ok, state}
  end

  defp handle_message({:notice, message}, state) do
    Logger.info("NOTICE from #{state.relay_url}: #{message}")
    registry_dispatch(:notice, message)
    {:ok, state}
  end

  defp handle_message(
         {:eose, subscription_id},
         state
       ) do
    registry_dispatch( subscription_id, "EOSE")
    {:ok, state}
  end

  defp handle_message({:close, sub_id}, state) do
    Logger.info("Deleting subscription #{sub_id}")
    RelayAgent.delete(self(), sub_id)
    {:ok, state}
  end

  defp handle_message({:ok, event_id, success, message}, state) do
    Logger.info("OK event #{event_id} from #{state.relay_url}, success? #{success}")
    # GenServer.reply(from, {:ok, event_id, message})
    registry_dispatch(:ok, message)
    {:ok, state}
  end

  defp handle_message(:error, state) do
    Logger.error(state)
    #registry_dispatch(:error, message)
    {:ok, state}
  end

  defp handle_message(_, state) do
    Logger.warning("unknown message received")
    {:ok, state}
  end

  @impl GenServer
  def terminate({:remote, :closed}, state) do
    Logger.info("Remote closed the connection - #{state.relay_url}")
    RelayAgent.delete(self())
    {:ok, state}
  end

  defp do_close(state) do
    # Streaming a close frame may fail if the server has already closed
    # for writing.
    _ = send_frame(state, :close)
    Mint.HTTP.close(state.conn)
    {:stop, :normal, state}
  end

  defp reply(state, response) do
    if state.caller, do: GenServer.reply(state.caller, response)
    put_in(state.caller, nil)
  end

  @doc """
  Send a message to a given pubsub topic
  """
  def registry_dispatch(sub_id, message) when is_binary(sub_id) do
    sub_id |> String.to_existing_atom() |> registry_dispatch(message)
  end

  def registry_dispatch(sub_id, message) when is_atom(sub_id) do
    Registry.dispatch(Nostrbase.PubSub, sub_id, fn entries ->
      for {pid, _} <- entries, do: send(pid, message)
    end)
  end
end
