defmodule NostrEx.TestSupport.FakeRelay do
  @moduledoc """
  Minimal relay server for tests, implemented on Cowboy's websocket behaviour.

  Each `start_link/1` starts an isolated HTTP listener on an ephemeral port
  that upgrades any request to a websocket and speaks NIP-01. Tests script
  Nostr messages to push to the connected client and assert on the raw frames
  the client sends.

      {:ok, relay} = FakeRelay.start_link()
      {:ok, _name} = NostrEx.connect(FakeRelay.url(relay))
      FakeRelay.push_eose(relay, sub_id)
      assert FakeRelay.wait_for(relay, &Enum.find(&1, &String.contains?(&1, "REQ")))

  Events pushed via `push_event/3` are genuinely signed (fixed test key), so
  they pass client-side validation.
  """

  use GenServer

  alias NostrCore.{Event, Message}

  @test_privkey "6dba065ffb6f51b4023d7d24a0c91c125c42ceff344d744d00f3c76e6cb5e03e"

  defstruct [:ref, :port, :ip_string, handlers: %{}, received: []]

  ## Public API

  @doc """
  Starts an isolated relay. Opts:
  - `:ip` - loopback address tuple to bind and report in the URL
    (default `{127, 0, 0, 1}`). Use e.g. `{127, 0, 0, 2}` to get a second
    relay with a *distinct hostname* (relay identity is host-based).
  - `:port` - fixed port to bind instead of an ephemeral one (for
    stop-the-relay-then-restart-on-same-port scenarios).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "The ws:// URL of this fake relay's ephemeral listener."
  @spec url(pid()) :: String.t()
  def url(server), do: "ws://#{ip_string(server)}:#{port(server)}"

  defp ip_string(server), do: GenServer.call(server, :ip_string)

  @spec port(pid()) :: :inet.port_number()
  def port(server), do: GenServer.call(server, :port)

  def stop(server), do: GenServer.stop(server)

  ## Scripting (broadcast to all live connections)

  @doc "Push a signed EVENT message for `sub_id`. Attrs are merged into kind-1 defaults."
  def push_event(server, sub_id, attrs \\ []) when is_binary(sub_id) do
    {:ok, event} = Event.create(1, Keyword.merge([content: "fake relay event"], attrs))
    {:ok, signed} = Event.sign(event, @test_privkey)
    push_raw_text(server, Message.serialize({:event, sub_id, signed}))
  end

  def push_eose(server, sub_id) when is_binary(sub_id),
    do: push_raw_text(server, Message.serialize({:eose, sub_id}))

  def push_closed(server, sub_id, reason \\ "") when is_binary(sub_id),
    do: push_raw_text(server, Message.serialize({:closed, sub_id, reason}))

  def push_ok(server, event_id, success \\ true, message \\ "") when is_binary(event_id),
    do: push_raw_text(server, Message.serialize({:ok, event_id, success, message}))

  def push_notice(server, message) when is_binary(message),
    do: push_raw_text(server, Message.serialize({:notice, message}))

  def push_auth_challenge(server, challenge) when is_binary(challenge),
    do: push_raw_text(server, Message.serialize({:auth, challenge}))

  @doc "Push an arbitrary pre-encoded JSON text frame."
  def push_raw_text(server, text) when is_binary(text),
    do: broadcast(server, {:relay_send, {:text, text}})

  @doc """
  Close all server-side TCP connections abruptly (no websocket close frame).

  NOTE: how quickly the client observes an abrupt drop is not deterministic
  — idle connections may not notice for seconds. Tests that assert on
  post-drop client state should use `close_gracefully/1` instead, or rely on
  keepalives once implemented.
  """
  def drop_connections(server), do: GenServer.cast(server, :force_drop)

  @doc "Send a proper websocket close frame, letting Cowboy finish the handshake."
  def close_gracefully(server), do: broadcast(server, {:relay_send, {:close, 1000, ""}})

  ## Inspection

  @doc "Raw text frames received from clients, in chronological order."
  @spec received(pid()) :: [String.t()]
  def received(server), do: GenServer.call(server, :received)

  def clear_received(server), do: GenServer.cast(server, :clear_received)

  @doc """
  Poll `received/1` until `fun` returns a non-nil value; returns that value or
  `{:error, :timeout}` after `timeout` ms.
  """
  def wait_for(server, fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(server, fun, deadline)
  end

  defp do_wait(server, fun, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      {:error, :timeout}
    else
      case fun.(received(server)) do
        nil ->
          Process.sleep(10)
          do_wait(server, fun, deadline)

        result ->
          result
      end
    end
  end

  ## Server callbacks

  @impl GenServer
  def init(opts) do
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})
    port = Keyword.get(opts, :port, 0)
    ref = make_ref()

    routes =
      :cowboy_router.compile([
        {:_, [{"/[...]", NostrEx.TestSupport.FakeRelay.Handler, %{relay: self()}}]}
      ])

    case :cowboy.start_clear(ref, [ip: ip, port: port], %{
           env: %{dispatch: routes}
         }) do
      {:ok, _pid} ->
        {:ok,
         %__MODULE__{
           ref: ref,
           port: :ranch.get_port(ref),
           ip_string: ip |> :inet.ntoa() |> List.to_string()
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  def handle_call(:ip_string, _from, state), do: {:reply, state.ip_string, state}

  def handle_call(:handlers, _from, state), do: {:reply, Map.values(state.handlers), state}

  def handle_call(:received, _from, state), do: {:reply, Enum.reverse(state.received), state}

  @impl GenServer
  def handle_cast({:conn_up, pid}, state) do
    ref = Process.monitor(pid)
    {:noreply, %{state | handlers: Map.put(state.handlers, ref, pid)}}
  end

  def handle_cast({:frame_in, text}, state),
    do: {:noreply, %{state | received: [text | state.received]}}

  def handle_cast(:clear_received, state), do: {:noreply, %{state | received: []}}

  def handle_cast({:broadcast, msg}, state) do
    for {_ref, pid} <- state.handlers, do: send(pid, msg)
    {:noreply, state}
  end

  def handle_cast(:force_drop, state) do
    # Close the TCP ports directly rather than killing the handler
    # processes: port_close produces an immediate FIN, while killing
    # leaves socket teardown to supervisor cleanup timing.
    for {_ref, pid} <- state.handlers do
      case :erlang.process_info(pid, :links) do
        {:links, links} ->
          Enum.each(links, fn
            port when is_port(port) -> :erlang.port_close(port)
            _pid -> :ok
          end)

        _ ->
          :ok
      end
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, %{state | handlers: Map.delete(state.handlers, ref)}}
  end

  @impl GenServer
  def terminate(_reason, state) do
    :cowboy.stop_listener(state.ref)
    :ok
  end

  defp broadcast(server, msg), do: GenServer.cast(server, {:broadcast, msg})
end

defmodule NostrEx.TestSupport.FakeRelay.Handler do
  @moduledoc false

  @behaviour :cowboy_websocket

  @impl true
  def init(req, state) do
    {:cowboy_websocket, req, state, %{idle_timeout: :infinity}}
  end

  @impl true
  def websocket_init(%{relay: relay} = state) do
    GenServer.cast(relay, {:conn_up, self()})
    {:ok, state}
  end

  @impl true
  def websocket_handle({:text, text}, %{relay: relay} = state) do
    GenServer.cast(relay, {:frame_in, text})
    {:ok, state}
  end

  def websocket_handle(_frame, state), do: {:ok, state}

  @impl true
  def websocket_info({:relay_send, frame}, state), do: {[frame], state}
end
