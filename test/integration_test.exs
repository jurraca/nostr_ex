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
end
