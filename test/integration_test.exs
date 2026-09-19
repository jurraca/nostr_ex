defmodule NostrEx.IntegrationTest do
  use ExUnit.Case

  alias NostrEx.TestSupport.FakeRelay

  @moduletag capture_log: true

  setup do
    # Transient restarts can land asynchronously after a previous test's
    # cleanup, leaving a blank socket registered globally. Purge any
    # leftovers so every test starts from a clean slate.
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

    test "failed handshake keeps a retrying socket and reports the error", %{relay: relay} do
      port = FakeRelay.port(relay)
      :ok = FakeRelay.stop(relay)

      assert {:error, _reason} =
               NostrEx.connect("ws://127.0.0.1:#{port}", readiness_timeout: 300)

      # The relay slot persists and keeps retrying instead of vanishing.
      eventually(fn ->
        assert [%{state: :backoff, name: "127.0.0.1"}] = NostrEx.RelayManager.get_states()
        assert NostrEx.list_relays() == ["127.0.0.1"]
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

    test "URL case is normalized: uppercase host maps to the same relay", %{relay: relay} do
      {:ok, _name} = NostrEx.connect(FakeRelay.url(relay))
      url = FakeRelay.url(relay)
      [scheme, rest] = String.split(url, "://", parts: 2)

      assert {:ok, "127.0.0.1"} = NostrEx.connect(String.upcase(scheme) <> "://" <> rest)
      assert length(NostrEx.RelayManager.active_pids()) == 1
    end
  end

  describe "sending to dead relays" do
    test "send_message to unknown relay returns error instead of raising" do
      assert {:error, :relay_down} = NostrEx.Socket.send_message("never_connected_relay", "x")
    end

    test "send_event after relay disconnect returns errors, caller survives", %{relay: relay} do
      {:ok, name} = NostrEx.connect(FakeRelay.url(relay))

      privkey = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
      {:ok, event} = NostrEx.create_event(1, content: "doomed")
      {:ok, signed} = NostrEx.sign_event(event, privkey)

      # Synchronous teardown: no transport-timing involved.
      :ok = NostrEx.disconnect(name)

      eventually(fn ->
        assert {:error, :not_found} = NostrEx.RelayManager.lookup(name)
      end)

      assert {:error, :no_relays, []} = NostrEx.send_event(signed)
    end

    test "sending to a killed socket recovers: respawn reconnects automatically", %{relay: relay} do
      {:ok, name} = NostrEx.connect(FakeRelay.url(relay))
      {:ok, pid} = NostrEx.RelayManager.lookup(name)

      # Abnormal exit: permanent restart respawns the slot, which immediately
      # begins connecting again - no more blank zombies.
      Process.exit(pid, :kill)

      eventually(fn ->
        assert {:ok, new_pid} = NostrEx.RelayManager.lookup(name)
        assert Process.alive?(new_pid)
        assert match?(%{ready?: true}, NostrEx.Socket.get_status(new_pid))
      end)

      # The recovered socket accepts sends.
      assert :ok = NostrEx.Socket.send_message(name, "[]")
    end

    test "send_event delivers to all connected relays concurrently" do
      {:ok, ra} = FakeRelay.start_link()
      {:ok, rb} = FakeRelay.start_link(ip: {127, 0, 0, 2})

      {:ok, name_a} = NostrEx.connect(FakeRelay.url(ra))
      {:ok, _name_b} = NostrEx.connect(FakeRelay.url(rb))

      privkey = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
      {:ok, event} = NostrEx.create_event(1, content: "broadcast")
      {:ok, signed} = NostrEx.sign_event(event, privkey)

      assert {:ok, event_id, []} = NostrEx.send_event(signed)

      for {relay, host} <- [{ra, "127.0.0.1"}, {rb, "127.0.0.2"}] do
        assert frame =
                 FakeRelay.wait_for(relay, fn msgs ->
                   Enum.find(msgs, &String.contains?(&1, ~s("EVENT")))
                 end),
               "relay #{host} never received the event"

        assert ["EVENT", %{"id" => ^event_id}] = JSON.decode!(frame)
      end

      assert name_a in NostrEx.list_relays()
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

      # Unknown send_via entries surface as failures instead of vanishing.
      assert {:ok, _event_id2, [{:totally_bogus_relay, :not_connected}]} =
               NostrEx.send_event(signed, send_via: [live_name, :totally_bogus_relay])

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
  describe "subscription bookkeeping" do
    test "relay-rejected subscription is cleaned up and never resurrected", %{relay: relay} do
      {:ok, name} = NostrEx.connect(FakeRelay.url(relay))

      {:ok, sub} = NostrEx.create_sub(kinds: [999_001], limit: 1)
      :ok = NostrEx.listen(sub)

      {:ok, _sub_id, _failures} = NostrEx.send_sub(sub, send_via: [name])

      # Record-before-send invariant: the entry exists as soon as the REQ
      # has been written.
      eventually(fn ->
        assert sub.id in NostrEx.RelayAgent.subscription_ids(name)
      end)

      # Relay rejects the REQ with CLOSED.
      FakeRelay.push_closed(relay, sub.id, "unsupported")

      eventually(fn ->
        assert [] == NostrEx.RelayAgent.subscription_ids(name)
      end)

      # Give any resurrection race a chance to manifest.
      Process.sleep(100)
      refute sub.id in NostrEx.RelayAgent.subscription_ids(name)
    end

    test "delete_subscription on an unknown relay plants no phantom key" do
      :ok = NostrEx.RelayAgent.delete_subscription("never_seen_relay", "sub_x")
      refute Map.has_key?(NostrEx.RelayAgent.state(), "never_seen_relay")
    end

    test "send_sub to disconnected relay records nothing", %{relay: relay} do
      {:ok, name} = NostrEx.connect(FakeRelay.url(relay))
      {:ok, sub} = NostrEx.create_sub(kinds: [1])
      :ok = NostrEx.listen(sub)

      # Synchronous teardown: no transport-timing involved.
      :ok = NostrEx.disconnect(name)

      eventually(fn ->
        assert {:error, :not_found} = NostrEx.RelayManager.lookup(name)
      end)

      assert {:error, :no_relays, []} = NostrEx.send_sub(sub)
      assert NostrEx.list_subs() == []
    end
  end

  describe "transport close handling" do
    # Mint delivers {tag, socket} messages; the tag depends on the transport
    # (:tcp for ws://, :ssl for wss://). The clauses must treat both alike.
    @tags [:tcp_closed, :ssl_closed]

    test "either transport-close tag notifies, backs off, and recovers", %{relay: relay} do
      :ok = NostrEx.listen(:relay_events)

      for tag <- @tags do
        {:ok, name} = NostrEx.connect(FakeRelay.url(relay))
        {:ok, pid} = NostrEx.RelayManager.lookup(name)
        assert %{ready?: true} = NostrEx.Socket.get_status(pid)

        # Synthesize the exact message shape Mint delivers on transport death.
        send(pid, {tag, :fake_socket})

        assert_receive {:relay_down, ^name, _reason}, 5_000

        # The socket stays registered, re-connects on its own, and announces it.
        eventually(fn ->
          assert {:ok, ^pid} = NostrEx.RelayManager.lookup(name)
          assert match?(%{ready?: true}, NostrEx.Socket.get_status(pid))
        end)

        assert_receive {:relay_up, ^name}, 10_000
      end
    end
  end

  describe "reconnect and resubscribe" do
    @fast_backoff [backoff_min: 20, backoff_max: 50]

    test "retry cadence during a reject window, then recovery with replay", %{relay: relay} do
      {:ok, name} = NostrEx.connect(FakeRelay.url(relay), @fast_backoff)
      {:ok, sub} = NostrEx.subscribe(kinds: [1])

      base_count = FakeRelay.connection_count(relay)

      # Deterministic outage: existing conn gets a close frame (processed
      # client-side, no TCP-timing), new conns are 1013-rejected for 600ms.
      :ok = FakeRelay.reject_window(relay, 600)
      FakeRelay.close_gracefully(relay)

      eventually(fn ->
        assert %{state: :backoff} = status(lookup!(name))
      end)

      # Still inside the window: retries land and get rejected.
      Process.sleep(400)
      mid_count = FakeRelay.connection_count(relay)
      assert mid_count >= base_count + 2, "expected retry attempts, got #{mid_count}"

      # Window expires; the next attempt succeeds and replays the REQ.
      eventually(fn ->
        assert %{ready?: true, attempt: 0} = status(lookup!(name))

        reqs = Enum.count(FakeRelay.received(relay), &String.contains?(&1, "\"REQ\""))
        assert reqs >= 2, "expected replayed REQ, got #{reqs}"
      end)

      FakeRelay.push_event(relay, sub.id)

      sub_id = sub.id
      assert_receive {:event, ^sub_id, %NostrCore.Event{}}, 5_000
    end

    test "max_attempts exhausts the retry loop and removes the relay slot" do
      {:ok, relay} = FakeRelay.start_link()
      url = FakeRelay.url(relay)
      :ok = FakeRelay.stop(relay)

      :ok = NostrEx.listen(:relay_events)

      opts = [
        backoff_min: 20,
        backoff_max: 30,
        max_attempts: 3,
        readiness_timeout: 200
      ]

      assert {:error, _} = NostrEx.connect(url, opts)

      # Give-up is announced on the lifecycle topic.
      assert_receive {:relay_failed, "127.0.0.1", 3}, 5_000

      # The slot is gone: not registered, not resurrectable.
      eventually(fn ->
        assert {:error, :not_found} = NostrEx.RelayManager.lookup("127.0.0.1")
        refute "127.0.0.1" in NostrEx.RelayManager.registered_names()
      end)

      # Still gone after a grace period: no supervisor respawn.
      Process.sleep(300)
      assert {:error, :not_found} = NostrEx.RelayManager.lookup("127.0.0.1")
    end

    test "subscription recorded during an outage applies on recovery" do
      port = 21_111

      {:ok, relay_a} = FakeRelay.start_link(port: port)
      url = FakeRelay.url(relay_a)
      {:ok, name} = NostrEx.connect(url, @fast_backoff)
      :ok = FakeRelay.stop(relay_a)

      # Wait until the surviving slot notices the loss before asserting.
      eventually(fn ->
        refute match?(%{ready?: true}, status(lookup!(name)))
      end)

      # Slot persists in backoff after the relay dies.
      assert {:error, _} =
               NostrEx.connect(url, Keyword.put(@fast_backoff, :readiness_timeout, 300))

      {:ok, sub} = NostrEx.create_sub(kinds: [1])
      :ok = NostrEx.listen(sub)

      # Recorded even though the write fails - outage-queued.
      assert {:error, "subscribe failed", [{^name, :not_ready}]} =
               NostrEx.send_sub(sub, send_via: [name])

      assert sub.id in NostrEx.list_subs()

      # A relay comes back on the same address; the socket reconnects and
      # the queued REQ is delivered.
      {:ok, relay_b} = FakeRelay.start_link(port: port)

      eventually(fn ->
        assert %{ready?: true} = status(lookup!(name))

        req =
          FakeRelay.wait_for(relay_b, fn msgs ->
            Enum.find(msgs, &String.contains?(&1, "\"REQ\""))
          end)

        assert is_binary(req)
      end)

      FakeRelay.push_eose(relay_b, sub.id)
      sub_id = sub.id
      assert_receive {:eose, ^sub_id, _host}, 5_000
    end

    defp lookup!(name) do
      {:ok, pid} = NostrEx.RelayManager.lookup(name)
      pid
    end

    defp status(pid), do: NostrEx.Socket.get_status(pid)
  end

  describe "publish acknowledgements" do
    test "publisher receives its own OK ack on the selective topic", %{relay: relay} do
      {:ok, name} = NostrEx.connect(FakeRelay.url(relay))

      privkey = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
      {:ok, event} = NostrEx.create_event(1, content: "ack me")
      {:ok, signed} = NostrEx.sign_event(event, privkey)

      :ok = NostrEx.listen({:ok, signed.id})
      assert {:ok, event_id, []} = NostrEx.send_event(signed)

      assert_receive {:publish_ack, ^event_id, %{success: true, message: "", relay: ^name}},
                     5_000
    end

    test "acks are isolated per event id" do
      {:ok, relay} = FakeRelay.start_link()
      {:ok, _name} = NostrEx.connect(FakeRelay.url(relay))

      privkey = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

      {:ok, e1} = NostrEx.create_event(1, content: "one")
      {:ok, s1} = NostrEx.sign_event(e1, privkey)
      {:ok, e2} = NostrEx.create_event(1, content: "two")
      {:ok, s2} = NostrEx.sign_event(e2, privkey)

      # Listening to s1 only: s2's ack must never land on this topic.
      :ok = NostrEx.listen({:ok, s1.id})

      {:ok, _, []} = NostrEx.send_event(s1)
      {:ok, _, []} = NostrEx.send_event(s2)

      event_id = s1.id
      assert_receive {:publish_ack, ^event_id, _}, 5_000
      refute_receive {:publish_ack, _, _}, 200
    end

    test "rejections surface with success: false and the relay message", %{relay: relay} do
      {:ok, _name} = NostrEx.connect(FakeRelay.url(relay))

      privkey = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
      {:ok, event} = NostrEx.create_event(1, content: "will be rejected")
      {:ok, signed} = NostrEx.sign_event(event, privkey)

      :ok = NostrEx.listen({:ok, signed.id})
      {:ok, event_id, []} = NostrEx.send_event(signed)

      FakeRelay.push_ok(relay, signed.id, false, "invalid: too dumb")

      assert_receive {:publish_ack, ^event_id, %{success: false, message: "invalid: too dumb"}},
                     5_000
    end

    test "each relay answers on the same topic in multi-relay publishes" do
      {:ok, ra} = FakeRelay.start_link()
      {:ok, rb} = FakeRelay.start_link(ip: {127, 0, 0, 2})

      {:ok, na} = NostrEx.connect(FakeRelay.url(ra))
      {:ok, nb} = NostrEx.connect(FakeRelay.url(rb))

      privkey = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
      {:ok, event} = NostrEx.create_event(1, content: "fanout acks")
      {:ok, signed} = NostrEx.sign_event(event, privkey)

      :ok = NostrEx.listen({:ok, signed.id})
      {:ok, event_id, []} = NostrEx.send_event(signed)

      acks =
        for _ <- 1..2 do
          assert_receive {:publish_ack, ^event_id, info}, 5_000
          info
        end

      relays = Enum.map(acks, & &1.relay) |> Enum.sort()
      assert relays == Enum.sort([na, nb])
      assert Enum.all?(acks, & &1.success)
    end

    test "the global :ok topic is gone" do
      assert_raise FunctionClauseError, fn -> apply(NostrEx, :listen, [:ok]) end
    end
  end

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
