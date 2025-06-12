defmodule Nostrbase.Socket do
  @moduledoc """
  A GenServer implementing a websocket connection to a relay.

  Once it is in `ready?: true` state, messages can be sent via `send_message/2`,
  with arguments either the `pid` or the `name` registered on `init`, and the encoded Nostr message to send.

  There are two other API function for this GenServer: `connect/1` to connect to a relay via the GenServer process started at `pid`,
  and `get_status/1`, which returns a subset of the state:
  ```
    %{
      url: URI.to_string(state.uri),
      name: state.name,
      closing?: state.closing?,
      ready?: state.ready?
    }
  ```

  The `send_message/2` function sends a message over the websocket, and does not expect a response.
  It is a `call`, and will return `:ok` if the socket was in a ready state and successfully sent the message, and `:error` otherwise.
  Responses will be sent via the websocket as Nostr messages.

  Before terminating, the process will update the `RelayAgent` to delete subscription info associated with this relay.
  """

  use GenServer, restart: :transient

  require Logger
  require Mint.HTTP

  alias Nostrbase.{RelayAgent, RelayManager, RelayRegistry}
  alias Nostr.Message

  @default_connect_timeout 3_000
  @default_call_timeout 5_000

  defstruct [
    :uri,
    :conn,
    :websocket,
    :request_ref,
    :caller,
    :status,
    :resp_headers,
    :name,
    closing?: false,
    ready?: false
  ]

  ## Public API

  def start_link(%{uri: uri, name: name}) do
    GenServer.start_link(__MODULE__, {uri, name}, name: via_tuple(name))
  end

  @doc """
  Connect to a relay.
  The GenServer process is first started with the relay name on `init/1`, and connected to separately via this function,
  since it may take an arbitrary amount of time.
  By default, the timeout is 3 seconds to connect and upgrade the connection to a websocket.

  The connection still needs to complete the handshake to be ready to receive messages,
  therefore it is recommended to check the socket's `ready?` status via `get_status/1` before sending messages.
  """
  def connect(pid, timeout \\ @default_connect_timeout) do
    try do
      GenServer.call(pid, :connect, timeout)
    catch
      :exit, {:timeout, _} ->
        {:error, "connection timed out after #{timeout}ms. Is your URL correct?"}

      :exit, reason ->
        {:error, "connection failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Send a serialized message to the relay via the connection at this `pid`.
  """
  def send_message(pid, text) when is_pid(pid) and is_binary(text) do
    GenServer.call(pid, {:send_text, text}, @default_call_timeout)
  end

  def send_message(relay_name, text) when is_atom(relay_name) and is_binary(text) do
    case RelayManager.lookup(relay_name) do
      {:ok, pid} -> send_message(pid, text)
      error -> error
    end
  end

  def send_message(relay_name, text) when is_binary(relay_name) and is_binary(text) do
    relay_name
    |> String.to_existing_atom()
    |> send_message(text)
  rescue
    ArgumentError -> {:error, "relay not found: #{relay_name}"}
  end

  def send_message(relay_name, _text) do
    {:error,
     "invalid relay_name format, expected atom, binary, or pid, got: #{inspect(relay_name)}"}
  end

  @doc """
  Get the status of the current connection.
  Returns the `url`, `name`, `ready?` and `closing?` args from the state.
  """
  def get_status(pid) do
    GenServer.call(pid, :status, @default_call_timeout)
  end

  ## GenServer Callbacks

  @impl GenServer
  def init({uri, name}) do
    {:ok, %__MODULE__{uri: uri, name: name}}
  end

  @impl GenServer
  def handle_call(:connect, from, %{uri: uri} = state) do
    case establish_connection(uri) do
      {:ok, conn, request_ref} ->
        new_state = %{state | conn: conn, request_ref: request_ref, caller: from}
        {:noreply, new_state}

      {:error, reason} ->
        {:stop, :normal, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_call({:send_text, text}, _from, %{ready?: true} = state) do
    case send_text_frame(state, text) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, reason, new_state} ->
        Logger.warning("Failed to send message: #{inspect(reason)}")
        {:reply, {:error, reason}, new_state}
    end
  end

  @impl GenServer
  def handle_call({:send_text, _text}, _from, %{ready?: false} = state) do
    {:reply, {:error, :not_ready}, state}
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    status_data = build_status(state)
    {:reply, status_data, state}
  end

  @impl GenServer
  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        new_state =
          %{state | conn: conn}
          |> handle_responses(responses)

        if new_state.closing? do
          do_close(new_state)
        else
          {:noreply, new_state}
        end

      {:error, conn, reason, _responses} ->
        Logger.error("WebSocket stream error: #{inspect(reason)}")
        new_state = %{state | conn: conn} |> reply_to_caller({:error, reason})
        {:noreply, new_state}

      :unknown ->
        {:noreply, state}
    end
  end

  @impl GenServer
  def terminate(reason, state) do
    case reason do
      {:remote, :closed} ->
        Logger.info("Remote closed the connection - #{state.uri.host}")

      _other ->
        Logger.info("Terminating connection to #{state.uri.host}: #{inspect(reason)}")
    end

    RelayAgent.delete_relay(state.name)
  end

  ## Private Functions

  defp via_tuple(name), do: {:via, Registry, {RelayRegistry, name}}

  defp establish_connection(uri) do
    http_scheme = if uri.scheme == "wss", do: :https, else: :http
    ws_scheme = String.to_existing_atom(uri.scheme)

    with {:ok, conn} <- Mint.HTTP.connect(http_scheme, uri.host, uri.port, protocols: [:http1]),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(ws_scheme, conn, uri.path, []) do
      {:ok, conn, ref}
    else
      {:error, reason} when is_list(reason) ->
        error_msg =
          cond do
            Keyword.get(reason, :nxdomain) -> "Invalid domain: #{uri.host}"
            Keyword.get(reason, :econnrefused) -> "Connection refused to #{uri.host}:#{uri.port}"
            true -> "Connection failed: #{inspect(reason)}"
          end

        {:error, error_msg}

      {:error, reason} ->
        Logger.error("Connection error: #{inspect(reason)}")
        {:error, "Connection failed"}

      {:error, _conn, reason} ->
        {:error, "WebSocket upgrade failed: #{inspect(reason)}"}
    end
  end

  defp send_text_frame(state, text) do
    case send_frame(state, {:text, text}) do
      {:ok, new_state} ->
        {:ok, new_state}

      {:error, :closed} ->
        {:error, :connection_closed, %{state | closing?: true, ready?: false}}

      {:error, %Mint.TransportError{reason: :closed}} ->
        {:error, :connection_closed, %{state | closing?: true, ready?: false}}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp build_status(state) do
    %{
      url: URI.to_string(state.uri),
      name: state.name,
      closing?: state.closing?,
      ready?: state.ready?
    }
  end

  defp handle_responses(state, responses) do
    Enum.reduce(responses, state, &handle_response/2)
  end

  defp handle_response({:status, ref, status}, %{request_ref: ref} = state) do
    %{state | status: status}
  end

  defp handle_response({:headers, ref, resp_headers}, %{request_ref: ref} = state) do
    %{state | resp_headers: resp_headers}
  end

  defp handle_response({:done, ref}, %{request_ref: ref} = state) do
    case Mint.WebSocket.new(state.conn, ref, state.status, state.resp_headers) do
      {:ok, conn, websocket} ->
        %{state | conn: conn, websocket: websocket, status: nil, resp_headers: nil, ready?: true}
        |> reply_to_caller({:ok, :connected})

      {:error, conn, reason} ->
        Logger.error("WebSocket creation failed: #{inspect(reason)}")

        %{state | conn: conn}
        |> reply_to_caller({:error, reason})
    end
  end

  defp handle_response({:data, ref, data}, %{request_ref: ref, websocket: websocket} = state)
       when not is_nil(websocket) do
    case Mint.WebSocket.decode(websocket, data) do
      {:ok, websocket, frames} ->
        %{state | websocket: websocket}
        |> handle_frames(frames)

      {:error, websocket, reason} ->
        Logger.error("WebSocket decode error: #{inspect(reason)}")

        %{state | websocket: websocket}
        |> reply_to_caller({:error, reason})
    end
  end

  defp handle_response(_response, state), do: state

  defp send_frame(state, frame) do
    with {:ok, websocket, data} <- Mint.WebSocket.encode(state.websocket, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.request_ref, data) do
      {:ok, %{state | websocket: websocket, conn: conn}}
    else
      {:error, %Mint.WebSocket{}, %{reason: :closed}} ->
        {:error, :closed}

      {:error, %Mint.WebSocket{}, reason} ->
        {:error, reason}

      {:error, _conn, reason} ->
        {:error, reason}
    end
  end

  defp handle_frames(state, frames) do
    Enum.reduce(frames, state, &handle_frame/2)
  end

  defp handle_frame({:ping, data}, state) do
    case send_frame(state, {:pong, data}) do
      {:ok, new_state} -> new_state
      # Continue on ping/pong errors
      {:error, _reason} -> state
    end
  end

  defp handle_frame({:close, _code, reason}, state) do
    Logger.debug("Received close frame: #{inspect(reason)}")
    %{state | closing?: true}
  end

  defp handle_frame({:text, text}, state) do
    text
    |> Message.parse()
    |> handle_nostr_message(state)

    state
  end

  defp handle_frame(frame, state) do
    Logger.debug("Unexpected frame received: #{inspect(frame)}")
    state
  end

  defp handle_nostr_message({:event, subscription_id, _} = event, _state) do
    Logger.debug("Received event for subscription #{subscription_id}")
    registry_dispatch(subscription_id, event)
  end

  defp handle_nostr_message({:notice, message}, state) do
    Logger.info("NOTICE from #{state.uri.host}: #{message}")
  end

  defp handle_nostr_message({:eose, subscription_id}, state) do
    Logger.debug("End of stored events for subscription #{subscription_id}")
    registry_dispatch(subscription_id, {:eose, subscription_id, state.uri.host})
  end

  defp handle_nostr_message({:close, sub_id}, state) do
    Logger.debug("Subscription #{sub_id} closed by relay")
    RelayAgent.delete_subscription(state.name, sub_id)
  end

  defp handle_nostr_message({:ok, event_id, success, message}, state) do
    status = if success, do: "accepted", else: "rejected"
    reason = if message == "", do: "no reason given", else: message
    Logger.info("Event #{event_id} from #{state.uri.host} #{status}: #{reason}")

    registry_dispatch(:ok, %{
      event_id: event_id,
      success: success,
      message: message,
      relay: state.uri.host
    })
  end

  defp handle_nostr_message(:error, state) do
    Logger.error("Parse error for message from #{state.uri.host}")
  end

  defp handle_nostr_message(unknown, state) do
    Logger.warning("Unknown message from #{state.uri.host}: #{inspect(unknown)}")
  end

  defp do_close(state) do
    # Streaming a close frame may fail if the server has already closed for writing
    _ = send_frame(state, :close)

    case state.conn do
      nil ->
        {:stop, :normal, state}

      conn ->
        Mint.HTTP.close(conn)
        {:stop, :normal, state}
    end
  end

  defp reply_to_caller(state, response) do
    case state.caller do
      nil ->
        state

      caller ->
        GenServer.reply(caller, response)
        %{state | caller: nil}
    end
  end

  @doc """
  Send a message to a given pubsub topic
  """
  def registry_dispatch(sub_id, message) when is_binary(sub_id) do
    Registry.dispatch(Nostrbase.PubSub, sub_id, fn entries ->
      for {pid, _} <- entries, do: send(pid, message)
    end)
  end

  def registry_dispatch(key, message) do
    Registry.dispatch(Nostrbase.PubSub, key, fn entries ->
      for {pid, _} <- entries, do: send(pid, message)
    end)
  end
end
