defmodule NostrEx.Listener do
  @moduledoc """
  A GenServer consumer to receive events.

  `use NostrEx.Listener`
  injects a GenServer that handles incoming messages for a subscription
  via callbacks.

      defmodule MyApp.NostrListener do
        use NostrEx.Listener

        @impl true
        def handle_event(sub_id, event, state) do
          # persist, broadcast to LiveViews, ...
          {:noreply, state}
        end
      end

      # application.ex
      {MyApp.NostrListener, []}

      # anywhere else in the app, regardless of which process created the sub:
      {:ok, sub, failures} =
        NostrEx.Listener.subscribe(MyApp.NostrListener, [authors: [pk], kinds: [3]])

  `handle_event/3` is required; every other callback (`handle_eose/3`,
  `handle_close/4`, `handle_notice/4`, `handle_publish_ack/3`,
  `handle_relay_event/2`) has a `defoverridable` no-op default, and unmatched
  messages land in `handle_message/2` (default: debug log). Wire vocabulary
  added later can't break existing listeners.

  Callers never override the injected `handle_info/2` / `handle_call/3`;
  extension happens through callbacks and `handle_message/2`.
  """

  alias NostrCore.Event

  @type state :: term()
  @type callback_return :: {:noreply, state()}
  @type topic ::
          binary()
          | {:ok, binary()}
          | :auth
          | :relay_events

  @doc "An event matched a subscription the listener is registered for."
  @callback handle_event(binary(), Event.t(), state()) :: callback_return()

  @doc "A relay sent EOSE (end of stored events) for a subscription."
  @callback handle_eose(binary(), binary(), state()) :: callback_return()

  @doc """
  A relay sent CLOSED for a subscription. Relay-sent closes without a reason
  (older relays) arrive with `message = nil`; NIP-01 reasons such as
  `"auth-required: ..."` are passed through.
  """
  @callback handle_close(binary(), binary(), String.t() | nil, state()) :: callback_return()

  @doc "A relay sent a NOTICE (not tied to relay health handling)."
  @callback handle_notice(binary(), binary(), String.t(), state()) :: callback_return()

  @doc """
  A relay acknowledged (or refused) a published event. Only fires when the
  listener was registered for `{:ok, event_id}` via `listen/2`.
  """
  @callback handle_publish_ack(binary(), map(), state()) :: callback_return()

  @doc """
  A connection lifecycle broadcast from the `:relay_events` topic —
  `{:relay_up, name}`, `{:relay_down, name, reason}`,
  `{:retry_scheduled, name, attempt, delay_ms}` or
  `{:relay_failed, name, attempts}`. Only fires when the listener was
  registered for `:relay_events`.
  """
  @callback handle_relay_event(tuple(), state()) :: callback_return()

  @doc """
  Any message that doesn't match the dispatch vocabulary (own `send/2`s,
  `:auth` topic maps, future wire kinds). The default implementation logs at
  debug level.
  """
  @callback handle_message(term(), state()) :: callback_return()

  @optional_callbacks handle_eose: 3,
                      handle_close: 4,
                      handle_notice: 4,
                      handle_publish_ack: 3,
                      handle_relay_event: 2,
                      handle_message: 2

  @doc """
  Register `listener` (pid or registered name) to receive messages for a
  `topic` — the same topics `NostrEx.listen/1` accepts: a subscription id,
  `{:ok, event_id}` for publish acks, `:relay_events`, `:auth`.

  The registration happens inside the listener process (subscription listeners
  belong to the process that registers), via a synchronous call, so a
  subsequent `NostrEx.send_sub/2` is guaranteed not to miss early events.

  Idempotent, matching `NostrEx.listen/1`.
  """
  @spec listen(GenServer.server(), topic()) :: :ok
  def listen(listener, topic) do
    GenServer.call(listener, {:nostr_ex_listen, topic})
  end

  @doc """
  Drop the listener's registration for `topic`. No-op if not registered.
  """
  @spec unlisten(GenServer.server(), topic()) :: :ok
  def unlisten(listener, topic) do
    GenServer.call(listener, {:nostr_ex_unlisten, topic})
  end

  @doc """
  Create a subscription, register `listener` for it, and send it to relays.

  The caller-needs-not-be-consumer sibling of `NostrEx.subscribe/2`: the
  caller orchestrates, the listener consumes. Unlike `NostrEx.subscribe/2`,
  send failures are returned (`{:ok, sub, failures}`) — when the caller isn't
  the consumer, they're its only signal that some relays didn't get the REQ.

  Registration is synchronous, so events can't be missed between this call
  and the REQ hitting the wire. If the send fails outright, the listener's
  registration is rolled back.

  ## Options
  - `:send_via` - relay names or URLs; defaults to all connected relays.

  ## Examples

      {:ok, sub, []} = NostrEx.Listener.subscribe(MyApp.NostrListener, kinds: [1])
      {:ok, sub, failures} =
        NostrEx.Listener.subscribe(MyApp.NostrListener, [authors: [pk], kinds: [3]],
          send_via: ["relay.damus.io"])
  """
  @spec subscribe(GenServer.server(), NostrEx.Subscription.filters_input(), keyword()) ::
          {:ok, NostrEx.Subscription.t(), [NostrEx.Client.failure()]}
          | {:error, term(), [NostrEx.Client.failure()]}
          | {:error, String.t()}
  def subscribe(listener, filters, opts \\ []) do
    case NostrEx.create_sub(filters) do
      {:error, reason} ->
        {:error, reason}

      {:ok, sub} ->
        :ok = listen(listener, sub.id)

        case NostrEx.send_sub(sub, send_via: opts[:send_via]) do
          {:ok, _sub_id, failures} ->
            {:ok, sub, failures}

          {:error, reason, failures} ->
            unlisten(listener, sub.id)
            {:error, reason, failures}
        end
    end
  end

  defmacro __using__(_opts) do
    quote location: :keep do
      use GenServer

      @behaviour NostrEx.Listener

      require Logger

      def start_link(opts \\ []) do
        GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
      end

      @impl true
      def init(opts), do: {:ok, opts}

      # Registration must happen in the listener process (see listen/2). The
      # atoms are prefixed so a user tuple can't collide with the protocol.
      @impl true
      def handle_call({:nostr_ex_listen, topic}, _from, state) do
        {:reply, NostrEx.listen(topic), state}
      end

      def handle_call({:nostr_ex_unlisten, topic}, _from, state) do
        {:reply, Registry.unregister(NostrEx.PubSub, topic), state}
      end

      @impl true
      def handle_info({:event, sub_id, event}, state), do: handle_event(sub_id, event, state)

      def handle_info({:eose, sub_id, relay}, state), do: handle_eose(sub_id, relay, state)

      def handle_info({:close, sub_id, relay}, state),
        do: handle_close(sub_id, relay, nil, state)

      def handle_info({:close, sub_id, relay, message}, state),
        do: handle_close(sub_id, relay, message, state)

      def handle_info({:notice, sub_id, relay, message}, state),
        do: handle_notice(sub_id, relay, message, state)

      def handle_info({:publish_ack, event_id, info}, state),
        do: handle_publish_ack(event_id, info, state)

      def handle_info({:relay_up, _name} = msg, state), do: handle_relay_event(msg, state)

      def handle_info({:relay_down, _name, _reason} = msg, state),
        do: handle_relay_event(msg, state)

      def handle_info({:retry_scheduled, _name, _attempt, _delay} = msg, state),
        do: handle_relay_event(msg, state)

      def handle_info({:relay_failed, _name, _attempts} = msg, state),
        do: handle_relay_event(msg, state)

      def handle_info(message, state), do: handle_message(message, state)

      @impl NostrEx.Listener
      def handle_eose(_sub_id, _relay, state), do: {:noreply, state}
      def handle_close(_sub_id, _relay, _message, state), do: {:noreply, state}
      def handle_notice(_sub_id, _relay, _message, state), do: {:noreply, state}
      def handle_publish_ack(_event_id, _info, state), do: {:noreply, state}
      def handle_relay_event(_event, state), do: {:noreply, state}

      def handle_message(message, state) do
        Logger.debug("#{inspect(__MODULE__)}: unhandled message #{inspect(message)}")
        {:noreply, state}
      end

      defoverridable start_link: 1,
                     init: 1,
                     handle_eose: 3,
                     handle_close: 4,
                     handle_notice: 4,
                     handle_publish_ack: 3,
                     handle_relay_event: 2,
                     handle_message: 2
    end
  end
end
