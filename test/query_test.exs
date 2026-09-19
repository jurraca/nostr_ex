defmodule NostrEx.QueryTest do
  use ExUnit.Case

  alias NostrEx.Query.Result
  alias NostrEx.TestSupport.FakeRelay
  alias NostrCore.Message

  @moduletag capture_log: true
  @privkey "6dba065ffb6f51b4023d7d24a0c91c125c42ceff344d744d00f3c76e6cb5e03e"

  setup do
    Enum.each(NostrEx.RelayManager.active_pids(), fn pid ->
      DynamicSupervisor.terminate_child(NostrEx.RelayManager, pid)
    end)

    {:ok, relay} = FakeRelay.start_link()

    on_exit(fn ->
      _ = NostrEx.close_all_subs()

      Enum.each(NostrEx.list_relays(), fn name ->
        _ = NostrEx.disconnect(name)
      end)
    end)

    {:ok, relay: relay}
  end

  # The query's sub id is generated internally, so the scripted relay
  # responses are driven from a helper that reads the REQ frame the client
  # sent. Runs in a separate process because the query blocks the caller.
  defp on_req(relay, fun) do
    spawn_link(fn -> fun.(wait_for_sub_id(relay)) end)
  end

  defp wait_for_sub_id(relay) do
    FakeRelay.wait_for(relay, fn msgs ->
      Enum.find_value(msgs, fn text ->
        case JSON.decode(text) do
          {:ok, ["REQ", sub_id | _]} -> sub_id
          _ -> nil
        end
      end)
    end)
  end

  defp close_received?(msgs) do
    Enum.any?(msgs, &String.contains?(&1, "\"CLOSE\""))
  end

  test "collects events until EOSE from the single relay", %{relay: relay} do
    {:ok, name} = NostrEx.connect(FakeRelay.url(relay))

    on_req(relay, fn sub_id ->
      FakeRelay.push_event(relay, sub_id, content: "one")
      FakeRelay.push_event(relay, sub_id, content: "two")
      FakeRelay.push_eose(relay, sub_id)
    end)

    assert {:ok, %Result{} = result} =
             NostrEx.query([kinds: [1]], send_via: [name], timeout: 2_000)

    assert result.completion == :eose
    assert Enum.map(result.events, & &1.content) == ["one", "two"]
    assert result.eose_from == [name]
    assert result.failures == []
    assert Result.complete?(result)

    assert FakeRelay.wait_for(relay, &if(close_received?(&1), do: :ok))
  end

  test "keeps partial events and times out when a relay never EOSEs" do
    {:ok, a} = FakeRelay.start_link()
    {:ok, b} = FakeRelay.start_link(ip: {127, 0, 0, 2})
    {:ok, name_a} = NostrEx.connect(FakeRelay.url(a))
    {:ok, name_b} = NostrEx.connect(FakeRelay.url(b))

    on_req(a, fn sub_id ->
      FakeRelay.push_event(a, sub_id, content: "from a")
      FakeRelay.push_eose(a, sub_id)
    end)

    assert {:ok, result} =
             NostrEx.query([kinds: [1]], send_via: [name_a, name_b], timeout: 300)

    assert result.completion == :timeout
    assert Enum.map(result.events, & &1.content) == ["from a"]
    assert result.eose_from == [name_a]
    refute Result.complete?(result)
  end

  test "a relay CLOSED counts as answered and is recorded", %{relay: relay} do
    {:ok, name} = NostrEx.connect(FakeRelay.url(relay))

    on_req(relay, fn sub_id ->
      FakeRelay.push_event(relay, sub_id, content: "before close")
      FakeRelay.push_closed(relay, sub_id, "auth-required: we can't serve you")
    end)

    assert {:ok, result} = NostrEx.query([kinds: [1]], send_via: [name], timeout: 2_000)

    assert result.completion == :eose
    assert result.closed_by == [{name, "auth-required: we can't serve you"}]
    assert Enum.map(result.events, & &1.content) == ["before close"]
  end

  test "deduplicates the same event arriving from multiple relays", %{relay: relay} do
    {:ok, name} = NostrEx.connect(FakeRelay.url(relay))
    {:ok, event} = NostrEx.create_event(1, content: "dupe")
    {:ok, signed} = NostrEx.sign_event(event, @privkey)

    on_req(relay, fn sub_id ->
      frame = Message.serialize({:event, sub_id, signed})
      FakeRelay.push_raw_text(relay, frame)
      FakeRelay.push_raw_text(relay, frame)
      FakeRelay.push_eose(relay, sub_id)
    end)

    assert {:ok, result} = NostrEx.query([kinds: [1]], send_via: [name], timeout: 2_000)
    assert length(result.events) == 1
  end

  test "stops early at :max_events", %{relay: relay} do
    {:ok, name} = NostrEx.connect(FakeRelay.url(relay))

    on_req(relay, fn sub_id ->
      for i <- 1..5, do: FakeRelay.push_event(relay, sub_id, content: "event #{i}")
    end)

    assert {:ok, result} =
             NostrEx.query([kinds: [1]], send_via: [name], timeout: 2_000, max_events: 2)

    assert result.completion == :max_events
    assert length(result.events) == 2
  end

  test "on_event fires per deduped event in arrival order and events are returned", %{
    relay: relay
  } do
    {:ok, name} = NostrEx.connect(FakeRelay.url(relay))
    test_pid = self()

    on_req(relay, fn sub_id ->
      FakeRelay.push_event(relay, sub_id, content: "a")
      FakeRelay.push_event(relay, sub_id, content: "b")
      FakeRelay.push_eose(relay, sub_id)
    end)

    assert {:ok, result} =
             NostrEx.query([kinds: [1]],
               send_via: [name],
               timeout: 2_000,
               on_event: fn event -> send(test_pid, {:callback, event.content}) end
             )

    assert_receive {:callback, "a"}
    assert_receive {:callback, "b"}
    assert Enum.map(result.events, & &1.content) == ["a", "b"]
  end

  test "an on_event error propagates but the subscription is still closed", %{relay: relay} do
    {:ok, name} = NostrEx.connect(FakeRelay.url(relay))

    on_req(relay, fn sub_id -> FakeRelay.push_event(relay, sub_id, content: "boom") end)

    assert_raise RuntimeError, "callback failed", fn ->
      NostrEx.query([kinds: [1]],
        send_via: [name],
        timeout: 2_000,
        on_event: fn _ -> raise "callback failed" end
      )
    end

    assert FakeRelay.wait_for(relay, &if(close_received?(&1), do: :ok))
  end

  test "surfaces unknown send_via entries in failures and proceeds", %{relay: relay} do
    {:ok, name} = NostrEx.connect(FakeRelay.url(relay))

    on_req(relay, fn sub_id ->
      FakeRelay.push_event(relay, sub_id, content: "ok")
      FakeRelay.push_eose(relay, sub_id)
    end)

    assert {:ok, result} =
             NostrEx.query([kinds: [1]],
               send_via: [name, "wss://nope.invalid"],
               timeout: 2_000
             )

    assert result.completion == :eose
    assert {"wss://nope.invalid", :not_connected} in result.failures
  end

  test "returns the fan-out error when no relay accepts the REQ" do
    assert {:error, :no_relays, [{"wss://nope.invalid", :not_connected}]} =
             NostrEx.query([kinds: [1]], send_via: ["wss://nope.invalid"], timeout: 500)
  end

  test "returns an error for invalid filters" do
    assert {:error, reason} = NostrEx.query("not filters")
    assert reason =~ "filters must be"
  end

  test "returns :no_relays when nothing is connected" do
    assert {:error, :no_relays, []} = NostrEx.query([kinds: [1]], timeout: 500)
  end
end
