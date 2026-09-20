defmodule NostrEx.ListenerTest do
  use ExUnit.Case

  alias NostrEx.TestSupport.FakeRelay
  alias NostrCore.Event

  @moduletag capture_log: true
  @privkey "6dba065ffb6f51b4023d7d24a0c91c125c42ceff344d744d00f3c76e6cb5e03e"

  # Counts how many callbacks each test needs to override: all of them report
  # to the test process, keyed by callback name.
  defmodule TestListener do
    use NostrEx.Listener

    @impl true
    def init(opts), do: {:ok, %{report_to: Keyword.fetch!(opts, :report_to)}}

    @impl true
    def handle_event(sub_id, event, state), do: report(state, :event, {sub_id, event})

    @impl true
    def handle_eose(sub_id, relay, state), do: report(state, :eose, {sub_id, relay})

    @impl true
    def handle_close(sub_id, relay, message, state),
      do: report(state, :close, {sub_id, relay, message})

    @impl true
    def handle_notice(sub_id, relay, message, state),
      do: report(state, :notice, {sub_id, relay, message})

    @impl true
    def handle_publish_ack(event_id, info, state),
      do: report(state, :publish_ack, {event_id, info})

    @impl true
    def handle_relay_event(event, state), do: report(state, :relay_event, event)

    @impl true
    def handle_message(message, state), do: report(state, :message, message)

    defp report(state, callback, payload) do
      send(state.report_to, {:listener, callback, payload})
      {:noreply, state}
    end
  end

  setup do
    # Purge leftovers from other tests so each test starts from a clean slate.
    Enum.each(NostrEx.RelayManager.active_pids(), fn pid ->
      DynamicSupervisor.terminate_child(NostrEx.RelayManager, pid)
    end)

    {:ok, relay} = FakeRelay.start_link()
    {:ok, listener} = TestListener.start_link(report_to: self())

    on_exit(fn ->
      _ = NostrEx.close_all_subs()

      Enum.each(NostrEx.list_relays(), fn name ->
        _ = NostrEx.disconnect(name)
      end)
    end)

    {:ok, relay: relay, listener: listener}
  end

  test "subscribe/3 routes events and EOSE to the listener's callbacks", %{
    relay: relay,
    listener: listener
  } do
    {:ok, name} = NostrEx.connect(FakeRelay.url(relay))

    assert {:ok, sub, []} =
             NostrEx.Listener.subscribe(listener, [kinds: [1]], send_via: [name])

    FakeRelay.push_event(relay, sub.id, content: "hello")
    FakeRelay.push_eose(relay, sub.id)

    assert_receive {:listener, :event, {sub_id, %Event{kind: 1, content: "hello"}}}, 2_000
    assert sub_id == sub.id
    assert_receive {:listener, :eose, {^sub_id, "127.0.0.1"}}

    # The REQ actually hit the wire.
    assert FakeRelay.wait_for(relay, fn msgs ->
             Enum.find(msgs, &String.contains?(&1, "\"REQ\""))
           end)
  end

  test "a relay CLOSED with a reason reaches handle_close/4", %{
    relay: relay,
    listener: listener
  } do
    {:ok, name} = NostrEx.connect(FakeRelay.url(relay))
    {:ok, sub, []} = NostrEx.Listener.subscribe(listener, [kinds: [1]], send_via: [name])

    FakeRelay.push_closed(relay, sub.id, "auth-required: we can't serve you")

    assert_receive {:listener, :close, {sub_id, "127.0.0.1", "auth-required: we can't serve you"}}
    assert sub_id == sub.id
  end

  test "a relay close without a reason arrives with nil message", %{
    relay: relay,
    listener: listener
  } do
    {:ok, name} = NostrEx.connect(FakeRelay.url(relay))
    {:ok, sub, []} = NostrEx.Listener.subscribe(listener, [kinds: [1]], send_via: [name])

    FakeRelay.push_raw_text(relay, JSON.encode!(["CLOSE", sub.id]))

    assert_receive {:listener, :close, {sub_id, "127.0.0.1", nil}}
    assert sub_id == sub.id
  end

  test "publish acknowledgements reach handle_publish_ack when listening on {:ok, event_id}",
       %{relay: relay, listener: listener} do
    {:ok, name} = NostrEx.connect(FakeRelay.url(relay))

    {:ok, event} = NostrEx.create_event(1, content: "gm")
    {:ok, signed} = NostrEx.sign_event(event, @privkey)

    :ok = NostrEx.Listener.listen(listener, {:ok, signed.id})
    {:ok, event_id, []} = NostrEx.send_event(signed, send_via: [name])

    assert_receive {:listener, :publish_ack, {^event_id, %{success: true}}}
  end

  test "the :relay_events topic fires handle_relay_event", %{relay: relay, listener: listener} do
    :ok = NostrEx.Listener.listen(listener, :relay_events)

    {:ok, name} = NostrEx.connect(FakeRelay.url(relay))

    assert_receive {:listener, :relay_event, {:relay_up, ^name}}
  end

  test "unlisten/2 stops delivery", %{relay: relay, listener: listener} do
    {:ok, name} = NostrEx.connect(FakeRelay.url(relay))
    {:ok, sub, []} = NostrEx.Listener.subscribe(listener, [kinds: [1]], send_via: [name])

    :ok = NostrEx.Listener.unlisten(listener, sub.id)

    FakeRelay.push_event(relay, sub.id, content: "not for me")

    refute_receive {:listener, :event, _}, 200
  end

  test "messages outside the dispatch vocabulary reach handle_message", %{listener: listener} do
    send(listener, {:weird, 42})

    assert_receive {:listener, :message, {:weird, 42}}
  end

  test "subscribe/3 returns the fan-out error when nothing can be delivered", %{
    listener: listener
  } do
    assert {:error, :no_relays, [{"wss://nope.invalid", :not_connected}]} =
             NostrEx.Listener.subscribe(listener, [kinds: [1]], send_via: "wss://nope.invalid")
  end

  test "subscribe/3 returns an error for invalid filters", %{listener: listener} do
    assert {:error, reason} = NostrEx.Listener.subscribe(listener, "not filters")
    assert reason =~ "filters must be"
  end
end
