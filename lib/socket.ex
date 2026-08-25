defmodule NostrEx.Socket do
  @moduledoc """
  A GenServer owning a relay slot: it connects itself, reconnects with
  exponential backoff on any failure, and replays its recorded
  subscriptions after each successful handshake.

  The process represents the relay (its Registry name exists from spawn),
  not the connection - being alive means trying to be ready. It only ever
  exits when the supervisor removes it (`RelayManager.disconnect/1`); a
  crash respawns a fresh socket that immediately starts connecting again.

  Once in `ready?: true` state messages can be sent via `send_message/2`,
  which returns `{:error, :not_ready}` while connecting or backing off.

  Status is available via `get_status/1`:
  ```
    %{
      url: URI.to_string(state.uri),
      name: state.name,
      state: :connecting | :ready | :backoff | :failed | :closing,
      closing?: state.closing?,
      ready?: state.ready?
    }
  ```

  Lifecycle transitions are announced on the `:relay_events` pubsub topic:
  `{:relay_up, name}`, `{:relay_down, name, reason}` and
  `{:retry_scheduled, name, attempt, delay_ms}`.
  """

  use GenServer, restart: :permanent

  require Logger

  alias NostrEx.{Backoff, RelayAgent, RelayRegistry}
  alias NostrCore.{Event, Message}

  @default_call_timeout 5_000
  @default_backoff_min 500
  @default_backoff_max 30_000

  defstruct [
    :uri,
    :conn,
    :websocket,
    :request_ref,
    :status,
    :resp_headers,
    :name,
    :lifecycle,
    :attempt,
    :retry_timer,
    :backoff_min,
    :backoff_max,
    :max_attempts,
    :last_error,
    closing?: false,
    ready?: false
  ]

  ## Public API

  @spec start_link(%{
          required(:uri) => URI.t(),
          required(:name) => String.t(),
          optional(:opts) => keyword()
        }) ::
          GenServer.on_start()
  def start_link(%{uri: uri, name: name} = args) do
    GenServer.start_link(__MODULE__, {uri, name, Map.get(args, :opts, [])}, name: via_tuple(name))
  end

  @doc """
  Send a serialized message to the relay via the connection at this relay name or `pid`.

  If the relay process is no longer running (or dies mid-send), returns
  `{:error, :relay_down}` rather than raising.
  """
  @spec send_message(pid() | String.t(), binary()) :: :ok | {:error, atom() | String.t()}
  def send_message(relay_name, text) when is_binary(relay_name) and is_binary(text) do
    safe_send_call(via_tuple(relay_name), text)
  end

  def send_message(pid, text) when is_pid(pid) and is_binary(text) do
    safe_send_call(pid, text)
  end

  def send_message(relay_name, _text) do
    {:error,
     "invalid relay_name format, expected a registered string or a pid, got: #{inspect(relay_name)}"}
  end

  defp safe_send_call(server, text) do
    GenServer.call(server, {:send_text, text}, @default_call_timeout)
  catch
    # A timed-out call leaves the send outcome unknown; report it as such.
    :exit, {:timeout, _} ->
      {:error, :send_timeout}

    # The socket process was gone before or during the call.
    :exit, _ ->
      {:error, :relay_down}
  end

  @doc """
  Get the status of the current connection.
  Returns the `url`, `name`, lifecycle `state`, `attempt`, `ready?` and
  `closing?`.
  """
  @spec get_status(pid()) :: %{
          url: String.t(),
          name: String.t(),
          state: :connecting | :ready | :backoff | :failed | :closing,
          attempt: non_neg_integer(),
          ready?: boolean(),
          closing?: boolean()
        }
  def get_status(pid) do
    GenServer.call(pid, :status, @default_call_timeout)
  end

  ## GenServer Callbacks

  @impl GenServer
  def init({uri, name, opts}) do
    Process.flag(:trap_exit, true)

    state = %__MODULE__{
      uri: uri,
      name: name,
      lifecycle: :connecting,
      attempt: 0,
      retry_timer: nil,
      backoff_min: Keyword.get(opts, :backoff_min, @default_backoff_min),
      backoff_max: Keyword.get(opts, :backoff_max, @default_backoff_max),
      max_attempts: Keyword.get(opts, :max_attempts, :infinity)
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl GenServer
  def handle_continue(:connect, state), do: attempt_connection(state)

  defp attempt_connection(state) do
    case establish_connection(state.uri) do
      {:ok, conn, request_ref} ->
        {:noreply, %{state | conn: conn, request_ref: request_ref, lifecycle: :connecting}}

      {:error, reason} ->
        connection_lost(reason, state)
    end
  end

  # A connection was lost or could not be established: tear it down and
  # enter the backoff loop. The process stays alive - only RelayManager
  # disconnect/1 removes it.
  defp connection_lost(reason, state) do
    was_ready? = state.ready?

    state =
      state
      |> Map.put(:last_error, reason)
      |> teardown_connection()
      |> Map.put(:ready?, false)

    if was_ready? do
      broadcast(:relay_events, {:relay_down, state.name, reason})
    end

    schedule_retry(state)
  end

  defp teardown_connection(%{conn: nil} = state), do: %{state | websocket: nil, request_ref: nil}

  defp teardown_connection(state) do
    _ = send_frame(state, :close)
    _ = Mint.HTTP.close(state.conn)
    %{state | conn: nil, websocket: nil, request_ref: nil}
  rescue
    _ -> %{state | conn: nil, websocket: nil, request_ref: nil}
  end

  defp schedule_retry(%{max_attempts: max} = state) when is_integer(max) do
    if state.attempt >= max do
      Logger.error("Relay #{state.uri.host}: giving up after #{state.attempt} attempts")
      {:noreply, %{state | lifecycle: :failed}}
    else
      do_schedule_retry(state)
    end
  end

  defp schedule_retry(state), do: do_schedule_retry(state)

  defp do_schedule_retry(state) do
    attempt = state.attempt + 1
    delay = Backoff.next_delay(attempt, min: state.backoff_min, max: state.backoff_max)

    Logger.warning(
      "Relay #{state.uri.host} down (#{state.last_error}); retry #{attempt} in #{delay}ms"
    )

    broadcast(:relay_events, {:retry_scheduled, state.name, attempt, delay})

    if is_reference(state.retry_timer), do: Process.cancel_timer(state.retry_timer)
    timer = Process.send_after(self(), :attempt, delay)

    {:noreply, %{state | lifecycle: :backoff, attempt: attempt, retry_timer: timer}}
  end

  @impl GenServer
  @spec handle_call({:send_text, binary()}, GenServer.from(), %__MODULE__{}) ::
          {:reply, :ok | {:error, atom()}, %__MODULE__{}}
  def handle_call({:send_text, text}, _from, %{ready?: true} = state) do
    case send_text_frame(state, text) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, reason, new_state} ->
        {:reply, {:error, reason}, new_state}
    end
  end

  @impl GenServer
  def handle_call({:send_text, _text}, _from, %{ready?: false} = state) do
    {:reply, {:error, :not_ready}, state}
  end

  @impl GenServer
  @spec handle_call(:status, GenServer.from(), %__MODULE__{}) ::
          {:reply, %{url: String.t(), name: String.t(), ready?: boolean(), closing?: boolean()},
           %__MODULE__{}}
  def handle_call(:status, _from, state) do
    status_data = build_status(state)
    {:reply, status_data, state}
  end

  @impl GenServer
  @spec handle_info(term(), %__MODULE__{}) ::
          {:noreply, %__MODULE__{}} | {:stop, :normal, %__MODULE__{}}
  # Supervisor shutdown (explicit disconnect terminates the child).
  def handle_info({:EXIT, _pid, reason}, state) do
    Logger.debug("Relay process exiting: #{inspect(reason)}")
    {:stop, :normal, state}
  end

  def handle_info(:attempt, %{lifecycle: :backoff} = state), do: attempt_connection(state)
  def handle_info(:attempt, state), do: {:noreply, state}

  # Late transport noise for an already-torn-down connection (e.g.
  # tcp_error racing connection_lost): nothing to stream through.
  def handle_info(_message, %{conn: nil} = state), do: {:noreply, state}

  def handle_info({tag, _socket}, state) when tag in [:tcp_closed, :ssl_closed] do
    Logger.debug("Transport closed by remote #{state.uri.host}.")
    connection_lost("closed by remote", state)
  end

  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        new_state =
          %{state | conn: conn}
          |> handle_responses(responses)

        if new_state.closing? do
          reason = new_state.last_error || "closed by remote"
          connection_lost(reason, new_state)
        else
          {:noreply, new_state}
        end

      {:error, _conn, %Mint.TransportError{reason: :closed}, _responses} ->
        connection_lost("closed by remote", state)

      {:error, conn, reason, _responses} ->
        Logger.error("WebSocket stream error: #{inspect(reason)}")
        {:noreply, %{state | conn: conn}}

      :unknown ->
        {:noreply, state}
    end
  end

  @impl GenServer
  @spec terminate(term(), %__MODULE__{}) :: :ok
  def terminate(_reason, state) do
    case RelayAgent.subscription_ids(state.name) do
      [] ->
        :ok

      sub_ids ->
        Enum.each(sub_ids, fn sub_id ->
          close_message =
            sub_id
            |> Message.close()
            |> Message.serialize()

          _ = send_close_frame(state, close_message)
        end)
    end

    RelayAgent.delete_relay(state.name)
    :ok
  end

  ## Private Functions

  @spec via_tuple(String.t()) :: {:via, Registry, {module(), String.t()}}
  defp via_tuple(name), do: {:via, Registry, {RelayRegistry, name}}

  @spec establish_connection(URI.t()) :: {:ok, Mint.HTTP.t(), reference()} | {:error, String.t()}
  defp establish_connection(uri) do
    http_scheme = if uri.scheme == "wss", do: :https, else: :http
    ws_scheme = String.to_atom(uri.scheme)

    with {:ok, conn} <- Mint.HTTP.connect(http_scheme, uri.host, uri.port, protocols: [:http1]),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(ws_scheme, conn, uri.path, []) do
      {:ok, conn, ref}
    else
      {:error, %Mint.TransportError{} = error} ->
        msg = Exception.message(error)
        {:error, "Connection error: #{msg}"}

      {:error, %Mint.HTTPError{} = error} ->
        msg = Exception.message(error)
        {:error, "HTTP error: #{msg}"}

      {:error, _conn, reason} ->
        {:error, "WebSocket upgrade failed: #{inspect(reason)}"}
    end
  end

  @spec send_text_frame(%__MODULE__{}, binary()) ::
          {:ok, %__MODULE__{}} | {:error, atom(), %__MODULE__{}}
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

  @spec build_status(%__MODULE__{}) :: %{
          url: String.t(),
          name: String.t(),
          state: :connecting | :ready | :backoff | :failed | :closing,
          attempt: non_neg_integer(),
          ready?: boolean(),
          closing?: boolean()
        }
  defp build_status(state) do
    %{
      url: URI.to_string(state.uri),
      name: state.name,
      state: state.lifecycle,
      attempt: state.attempt,
      closing?: state.closing?,
      ready?: state.ready?
    }
  end

  @spec handle_responses(%__MODULE__{}, list()) :: %__MODULE__{}
  defp handle_responses(state, responses) do
    Enum.reduce(responses, state, &handle_response/2)
  end

  @spec handle_response(tuple(), %__MODULE__{}) :: %__MODULE__{}
  defp handle_response({:status, ref, status}, %{request_ref: ref} = state) do
    %{state | status: status}
  end

  defp handle_response({:headers, ref, resp_headers}, %{request_ref: ref} = state) do
    %{state | resp_headers: resp_headers}
  end

  defp handle_response({:done, ref}, %{request_ref: ref} = state) do
    case Mint.WebSocket.new(state.conn, ref, state.status, state.resp_headers) do
      {:ok, conn, websocket} ->
        state =
          %{
            state
            | conn: conn,
              websocket: websocket,
              status: nil,
              resp_headers: nil,
              ready?: true,
              lifecycle: :ready,
              attempt: 0,
              closing?: false,
              last_error: nil
          }

        state = replay_subscriptions(state)
        broadcast(:relay_events, {:relay_up, state.name})
        state

      {:error, conn, reason} ->
        %{
          state
          | conn: conn,
            closing?: true,
            last_error: "upgrade failed: #{error_message(reason)}"
        }
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
    end
  end

  defp handle_response(_response, state), do: state

  # Mint errors arrive as exception structs; callers expect string reasons.
  defp error_message(reason) when is_exception(reason), do: Exception.message(reason)
  defp error_message(reason) when is_binary(reason), do: reason
  defp error_message(reason), do: inspect(reason)

  @spec send_frame(%__MODULE__{}, tuple() | atom()) ::
          {:ok, %__MODULE__{}} | {:error, atom() | term()}
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

  @spec handle_frames(%__MODULE__{}, list()) :: %__MODULE__{}
  defp handle_frames(state, frames) do
    Enum.reduce(frames, state, &handle_frame/2)
  end

  @spec handle_frame(tuple(), %__MODULE__{}) :: %__MODULE__{}
  defp handle_frame({:ping, data}, state) do
    case send_frame(state, {:pong, data}) do
      {:ok, new_state} -> new_state
      {:error, _reason} -> state
    end
  end

  defp handle_frame({:close, _code, _reason}, state) do
    %{state | closing?: true}
  end

  defp handle_frame({:text, text}, state) do
    case Message.parse(text) do
      {:ok, data} -> handle_nostr_message(data, state)
      {:error, _reason} -> state
    end
  end

  defp handle_frame(frame, state) do
    Logger.debug("Unexpected frame received: #{inspect(frame)}")
    state
  end

  @spec handle_nostr_message(tuple() | atom(), %__MODULE__{}) :: %__MODULE__{}
  defp handle_nostr_message({:event, subscription_id, _} = event, state) do
    registry_dispatch(subscription_id, event)
    state
  end

  defp handle_nostr_message({:notice, message}, state) do
    Logger.debug("NOTICE from #{state.uri.host}: #{message}")
    sub_ids = RelayAgent.subscription_ids(state.name)

    for sub_id <- sub_ids do
      registry_dispatch(sub_id, {:notice, sub_id, state.uri.host, message})
    end

    state
  end

  defp handle_nostr_message({:eose, subscription_id}, state) do
    registry_dispatch(subscription_id, {:eose, subscription_id, state.uri.host})
    state
  end

  defp handle_nostr_message({:close, sub_id}, state) do
    registry_dispatch(sub_id, {:close, sub_id, state.uri.host})
    RelayAgent.delete_subscription(state.name, sub_id)
    state
  end

  # Relay-initiated CLOSED (NIP-01): the relay is terminating the subscription.
  defp handle_nostr_message({:closed, sub_id, message}, state) do
    Logger.info("Relay #{state.uri.host} closed subscription #{sub_id}: #{message}")
    registry_dispatch(sub_id, {:close, sub_id, state.uri.host, message})
    RelayAgent.delete_subscription(state.name, sub_id)
    state
  end

  defp handle_nostr_message({:ok, event_id, success, message}, state) do
    info = %{event_id: event_id, success: success, message: message, relay: state.uri.host}

    if success do
      Logger.debug("OK #{String.slice(event_id, 0, 8)}… from #{state.uri.host}")
    else
      Logger.warning("Rejected by #{state.uri.host}: #{message} (#{event_id})")
    end

    # Selective topic: publishers listen({:ok, event_id}) before sending to
    # receive their own acks; there is deliberately no global ack broadcast.
    registry_dispatch({:ok, event_id}, {:publish_ack, event_id, info})

    state
  end

  # Relay-initiated AUTH (NIP-42): the relay is requesting authentication.
  # Clients `NostrEx.listen(:auth)` and receive `{:auth, %{challenge: c, relay: h}}`.
  defp handle_nostr_message({:auth, challenge}, state) when is_binary(challenge) do
    registry_dispatch(:auth, %{challenge: challenge, relay: state.uri.host})
    state
  end

  # Relay echoing back the client's AUTH event as an ack. Distinguished from
  # the challenge case by the event struct payload.
  defp handle_nostr_message({:auth, %Event{} = event}, state) do
    registry_dispatch(:auth, %{event: event, relay: state.uri.host})
    state
  end

  # NIP-45 COUNT reply. Sub-scoped topic `{:count, sub_id}`.
  defp handle_nostr_message({:count, sub_id, payload}, state) do
    registry_dispatch({:count, sub_id}, %{payload: payload, relay: state.uri.host})
    state
  end

  defp handle_nostr_message(unknown, state) do
    Logger.warning("Unknown message from #{state.uri.host}: #{inspect(unknown)}")
    state
  end

  # Replay every subscription recorded in the RelayAgent for this relay.
  # The Agent is the source of truth: entries survive process death, so a
  # crash-respawned socket restores subscriptions that were active before
  # the crash, and subs recorded during an outage apply on reconnect.
  @spec replay_subscriptions(%__MODULE__{}) :: %__MODULE__{}
  defp replay_subscriptions(state) do
    case RelayAgent.get(state.name) do
      nil ->
        state

      subs ->
        Enum.reduce(subs, state, fn {sub_id, payload}, acc ->
          case send_text_frame(acc, payload) do
            {:ok, new_acc} ->
              new_acc

            {:error, reason, new_acc} ->
              Logger.warning(
                "Relay #{state.uri.host}: failed to replay subscription #{sub_id}: #{inspect(reason)}"
              )

              new_acc
          end
        end)
    end
  end

  @doc """
  Send a message to a given pubsub topic
  """
  @spec registry_dispatch(atom() | binary(), term()) :: :ok
  def registry_dispatch(sub_id, message) do
    Registry.dispatch(NostrEx.PubSub, sub_id, fn entries ->
      for {pid, _} <- entries, do: send(pid, message)
    end)
  end

  defp broadcast(topic, message), do: registry_dispatch(topic, message)

  @spec send_close_frame(%__MODULE__{}, binary()) :: :ok
  defp send_close_frame(%{websocket: nil}, _message), do: :ok
  defp send_close_frame(%{conn: nil}, _message), do: :ok

  defp send_close_frame(%{websocket: websocket} = state, message) do
    case Mint.WebSocket.encode(websocket, {:text, message}) do
      {:ok, _websocket, data} ->
        _ = Mint.WebSocket.stream_request_body(state.conn, state.request_ref, data)
        :ok

      {:error, _reason} ->
        :ok
    end
  end
end
