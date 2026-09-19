defmodule NostrEx.Query do
  @moduledoc """
  One-shot (bounded) queries over relay subscriptions.

  On the wire, Nostr has no notion of a query: a REQ streams stored events,
  the relay sends EOSE, then keeps the REQ open until CLOSE. "One-shot" is a
  client-side convention — open the REQ, collect until every relay that
  received it has answered (EOSE or CLOSED), a timeout, or an event cap, then
  always CLOSE.

  `NostrEx.query/2` is the function-call counterpart to the process-scoped
  `NostrEx.subscribe/2`: use it to fetch a profile, a follow list, relay
  lists, or any bounded backfill where the caller wants the events back rather
  than an ongoing stream. Use `subscribe/2` when you need live updates.

  The query runs in the calling process (subscription listeners belong to the
  process that registers them), so it blocks until complete. Callers that must
  not block should run it in a `Task`.

  ## Examples

      {:ok, result} = NostrEx.query([authors: [pubkey], kinds: [3]], send_via: [relay])
      result.events
      result.eose_from

      # Stream each event into an app pipeline as it arrives:
      NostrEx.query([authors: pubkeys, kinds: [10002]],
        send_via: directory_relays,
        on_event: fn event -> send(ingest_pid, {:event, event}) end)
  """

  alias NostrEx.{Client, RelayAgent, Subscription, Utils}
  alias NostrEx.Query.Result

  @default_timeout 10_000

  @doc """
  Run a bounded query. See `NostrEx.query/2`.
  """
  @spec run(Subscription.filters_input(), keyword()) ::
          {:ok, Result.t()}
          | {:error, term(), [Client.failure()]}
          | {:error, String.t()}
  def run(filters, opts \\ []) do
    case Subscription.new(filters) do
      {:error, reason} ->
        {:error, reason}

      {:ok, sub} ->
        :ok = NostrEx.listen(sub.id)

        case Client.send_sub(sub, send_via: opts[:send_via]) do
          {:ok, sub_id, failures} ->
            execute(sub_id, failures, opts)

          {:error, reason, failures} ->
            # The REQ never reached a relay: don't leak the listener we
            # registered before sending.
            Registry.unregister(NostrEx.PubSub, sub.id)
            {:error, reason, failures}
        end
    end
  end

  defp execute(sub_id, failures, opts) do
    try do
      expected =
        sub_id
        |> RelayAgent.get_relays_for_sub()
        |> MapSet.new()

      deadline = System.monotonic_time(:millisecond) + (opts[:timeout] || @default_timeout)

      state = %{
        events: [],
        seen: MapSet.new(),
        expected: expected,
        eose_from: [],
        closed_by: [],
        completion: nil,
        on_event: opts[:on_event],
        max_events: opts[:max_events]
      }

      state
      |> loop(sub_id, deadline)
      |> build_result(sub_id, failures)
      |> then(&{:ok, &1})
    after
      # A leaked REQ is replayed by the relay agent on every reconnect, so
      # closing (and unregistering the listener) is guaranteed on success,
      # timeout, cap, callback crash and exit signals alike.
      _ = Client.close_sub(sub_id)
      Registry.unregister(NostrEx.PubSub, sub_id)
    end
  end

  # Terminates when every expected relay has answered (EOSE or CLOSED), the
  # event cap is reached, or the deadline passes. The expected set is seeded
  # from the relays that actually recorded the REQ, so a relay that never
  # received it can't block completion until timeout.
  defp loop(state, sub_id, deadline) do
    cond do
      MapSet.size(state.expected) == 0 ->
        %{state | completion: :eose}

      is_integer(state.max_events) and length(state.events) >= state.max_events ->
        %{state | completion: :max_events}

      true ->
        case deadline - System.monotonic_time(:millisecond) do
          remaining when remaining <= 0 ->
            %{state | completion: :timeout}

          remaining ->
            receive do
              {:event, ^sub_id, event} ->
                loop(handle_event(event, state), sub_id, deadline)

              {:eose, ^sub_id, host} ->
                loop(handle_eose(host, state), sub_id, deadline)

              {:close, ^sub_id, host, message} ->
                loop(handle_close(host, message, state), sub_id, deadline)

              {:close, ^sub_id, host} ->
                loop(handle_close(host, nil, state), sub_id, deadline)
            after
              remaining -> %{state | completion: :timeout}
            end
        end
    end
  end

  # Duplicate events are common when several relays hold the same event.
  # `on_event` fires only for the first sighting, in arrival order; errors
  # propagate (the caller's supervisor owns them) and the `after` cleanup
  # still closes the sub.
  defp handle_event(event, state) do
    if MapSet.member?(state.seen, event.id) do
      state
    else
      if is_function(state.on_event, 1), do: state.on_event.(event)

      %{
        state
        | events: [event | state.events],
          seen: MapSet.put(state.seen, event.id)
      }
    end
  end

  defp handle_eose(host, state) do
    name = Utils.name_from_host(host)
    %{state | expected: MapSet.delete(state.expected, name), eose_from: [name | state.eose_from]}
  end

  # A relay-sent CLOSED counts as answered — it will never EOSE — but is
  # recorded so callers can see *why* (auth-required, rate-limited, ...).
  defp handle_close(host, message, state) do
    name = Utils.name_from_host(host)

    %{
      state
      | expected: MapSet.delete(state.expected, name),
        closed_by: [{name, message} | state.closed_by]
    }
  end

  defp build_result(state, sub_id, failures) do
    %Result{
      sub_id: sub_id,
      events: Enum.reverse(state.events),
      eose_from: state.eose_from |> Enum.reverse() |> Enum.uniq(),
      closed_by: Enum.reverse(state.closed_by),
      completion: state.completion,
      failures: failures
    }
  end
end
