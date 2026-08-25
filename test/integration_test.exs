defmodule NostrEx.IntegrationTest do
  use ExUnit.Case

  alias NostrEx.TestSupport.FakeRelay

  setup do
    {:ok, relay} = FakeRelay.start_link()

    on_exit(fn ->
      _ = NostrEx.close_all_subs()

      Enum.each(NostrEx.list_relays(), fn name ->
        _ = NostrEx.disconnect(name)
      end)
    end)

    {:ok, relay: relay}
  end

  defp wait_for_req(relay) do
    req_text =
      FakeRelay.wait_for(relay, fn msgs ->
        Enum.find(msgs, &String.contains?(&1, "\"REQ\""))
      end)

    assert is_binary(req_text)
    req_text
  end

  test "connect -> subscribe -> receive event and eose", %{relay: relay} do
    assert {:ok, name} = NostrEx.connect(FakeRelay.url(relay))
    assert NostrEx.RelayManager.ready?(name)

    {:ok, sub} = NostrEx.subscribe(kinds: [1])
    wait_for_req(relay)

    FakeRelay.push_event(relay, sub.id)
    FakeRelay.push_eose(relay, sub.id)

    assert_receive {:event, sub_id, %NostrCore.Event{kind: 1}}, 2_000
    assert sub_id == sub.id
    assert_receive {:eose, ^sub_id, host}, 2_000
    assert host == "127.0.0.1"

    assert [req_text] = FakeRelay.received(relay)
    assert req_text =~ ~s("REQ")
  end

  describe "connect" do
    test "concurrent connects to the same relay yield one connection", %{relay: relay} do
      url = FakeRelay.url(relay)

      results =
        1..4
        |> Enum.map(fn _ -> Task.async(fn -> NostrEx.connect(url) end) end)
        |> Enum.map(&Task.await(&1, 10_000))

      assert Enum.all?(results, &match?({:ok, _name}, &1))
      assert [name] = Enum.uniq(for {:ok, n} <- results, do: n)

      eventually(fn ->
        assert NostrEx.RelayManager.ready?(name)
        assert length(NostrEx.RelayManager.active_pids()) == 1
      end)
    end

    test "failed handshake leaves no orphan child", %{relay: relay} do
      port = FakeRelay.port(relay)
      :ok = FakeRelay.stop(relay)

      assert {:error, _reason} = NostrEx.connect("ws://127.0.0.1:#{port}")

      eventually(fn ->
        assert NostrEx.RelayManager.active_pids() == []
      end)
    end

    test "connect heals when an existing socket dies before being used", %{relay: relay} do
      url = FakeRelay.url(relay)
      name = NostrEx.Utils.name_from_host(URI.parse(url).host)

      # Start a socket directly and kill it, leaving a stale registry corpse.
      {:ok, pid} =
        DynamicSupervisor.start_child(NostrEx.RelayManager, {
          NostrEx.Socket,
          %{uri: URI.parse(url) |> Map.put(:path, "/"), name: name}
        })

      Process.exit(pid, :kill)
      Process.sleep(50)

      assert {:ok, ^name} = NostrEx.connect(url)
      assert NostrEx.RelayManager.ready?(name)
    end

    test "sequential connect to an already-connected relay adds no child", %{relay: relay} do
      assert {:ok, name} = NostrEx.connect(FakeRelay.url(relay))
      assert {:ok, ^name} = NostrEx.connect(FakeRelay.url(relay))
      assert length(NostrEx.RelayManager.active_pids()) == 1
    end
  end

  describe "sending to dead relays" do
    test "send_message to unknown relay returns error instead of raising" do
      assert {:error, :relay_down} = NostrEx.Socket.send_message("never_connected_relay", "x")
    end

    test "send_event after relay close returns errors, caller survives", %{relay: relay} do
      {:ok, name} = NostrEx.connect(FakeRelay.url(relay))

      privkey = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
      {:ok, event} = NostrEx.create_event(1, content: "doomed")
      {:ok, signed} = NostrEx.sign_event(event, privkey)

      # Graceful websocket close: handled frame-by-frame by the socket
      # process itself, so teardown is deterministic (unlike abrupt
      # transport drops, whose client-visible timing is not).
      FakeRelay.close_gracefully(relay)

      eventually(fn ->
        assert {:error, :not_found} = NostrEx.RelayManager.lookup(name)
      end)

      # All relays have been cleaned up, so the event goes nowhere.
      # (Error shape is normalized by the error-contract alignment pass.)
      assert {:error, _} = NostrEx.send_event(signed)
    end

    test "sending to a killed-and-restarted socket errors without raising", %{relay: relay} do
      {:ok, name} = NostrEx.connect(FakeRelay.url(relay))
      {:ok, pid} = NostrEx.RelayManager.lookup(name)

      # Abnormal exit: transient restarts a blank socket under the same name.
      Process.exit(pid, :kill)

      eventually(fn ->
        assert {:ok, _new_pid} = NostrEx.RelayManager.lookup(name)
      end)

      assert match?({:error, _}, NostrEx.Socket.send_message(name, "[]"))
    end

    test "send_event targets only connected relays" do
      # Distinct loopback IPs: relay identity is hostname-based, so two
      # relays on 127.0.0.1 would collapse into a single connection.
      {:ok, live} = FakeRelay.start_link()
      {:ok, dead} = FakeRelay.start_link(ip: {127, 0, 0, 2})

      {:ok, live_name} = NostrEx.connect(FakeRelay.url(live))
      {:ok, dead_name} = NostrEx.connect(FakeRelay.url(dead))

      privkey = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
      {:ok, event} = NostrEx.create_event(1, content: "fanout")
      {:ok, signed} = NostrEx.sign_event(event, privkey)

      # Synchronous disconnect: terminate_child returns after the child is
      # gone, so no transport-timing is involved.
      :ok = NostrEx.disconnect(dead_name)

      eventually(fn ->
        assert {:error, :not_found} = NostrEx.RelayManager.lookup(dead_name)
      end)

      assert {:ok, event_id, []} = NostrEx.send_event(signed, send_via: [live_name])

      # Delivery is async; poll until the relay records the EVENT frame.
      frame =
        FakeRelay.wait_for(live, fn msgs ->
          Enum.find(msgs, &String.contains?(&1, ~s("EVENT")))
        end)

      assert is_binary(frame)

      assert ["EVENT", %{"id" => ^event_id}] = JSON.decode!(frame)
      assert match?({:error, _}, NostrEx.Socket.send_message(dead_name, "[]"))
    end
  end

  # Generous default: passing polls exit early; only genuine failures pay
  # the full budget. Tolerates occasional multi-second delivery jitter on
  # otherwise-idle loopback connections.
  defp eventually(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    fun.()
  rescue
    ExUnit.AssertionError ->
      if System.monotonic_time(:millisecond) > deadline do
        raise "eventually/2 timed out"
      else
        Process.sleep(20)
        do_eventually(fun, deadline)
      end
  end
end
