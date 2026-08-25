defmodule NostrEx.RelayAgentTest do
  use ExUnit.Case
  alias NostrEx.RelayAgent

  @payload ~s(["REQ","sub_1",{}])

  setup do
    RelayAgent.start_link(%{})

    on_exit(fn ->
      Agent.update(RelayAgent, fn _state -> %{} end)
    end)

    :ok
  end

  test "agent starts with empty state" do
    assert RelayAgent.state() == %{}
  end

  test "get returns nil for unknown relay" do
    assert RelayAgent.get("relay1") == nil
    assert RelayAgent.subscription_ids("relay1") == []
  end

  test "put_subscription records sub_id -> payload" do
    :ok = RelayAgent.put_subscription("relay1", "sub_1", @payload)

    assert RelayAgent.get("relay1") == %{"sub_1" => @payload}
    assert RelayAgent.subscription_ids("relay1") == ["sub_1"]
  end

  test "re-put is idempotent and refreshes payload" do
    :ok = RelayAgent.put_subscription("relay1", "sub_1", "old")
    :ok = RelayAgent.put_subscription("relay1", "sub_1", @payload)

    assert RelayAgent.get("relay1") == %{"sub_1" => @payload}
  end

  test "delete_subscription removes the relay key once empty" do
    :ok = RelayAgent.put_subscription("relay1", "sub_1", @payload)
    :ok = RelayAgent.delete_subscription("relay1", "sub_1")

    assert RelayAgent.get("relay1") == nil
  end

  test "delete_subscription keeps other subs of the same relay" do
    :ok = RelayAgent.put_subscription("relay1", "sub_1", "p1")
    :ok = RelayAgent.put_subscription("relay1", "sub_2", "p2")

    :ok = RelayAgent.delete_subscription("relay1", "sub_1")

    assert RelayAgent.subscription_ids("relay1") == ["sub_2"]
  end

  test "delete_subscription on unknown relay plants no phantom key" do
    :ok = RelayAgent.delete_subscription("never_seen", "sub_x")

    refute Map.has_key?(RelayAgent.state(), "never_seen")
  end

  test "can delete entire relay" do
    :ok = RelayAgent.put_subscription("relay1", "sub_1", @payload)
    :ok = RelayAgent.delete_relay("relay1")

    assert RelayAgent.get("relay1") == nil
  end

  test "can get relays for subscription" do
    :ok = RelayAgent.put_subscription("relay1", "sub_1", @payload)
    :ok = RelayAgent.put_subscription("relay2", "sub_1", @payload)

    relays = RelayAgent.get_relays_for_sub("sub_1")
    assert length(relays) == 2
    assert "relay1" in relays
    assert "relay2" in relays
  end

  test "inverts the relay->subs mapping to sub->relays" do
    :ok = RelayAgent.put_subscription("relay.damus.io", "sub_1", "p")
    :ok = RelayAgent.put_subscription("relay.damus.io", "sub_2", "p")
    # sub_1 on both relays
    :ok = RelayAgent.put_subscription("relay.nostr.band", "sub_1", "p")

    result = RelayAgent.get_relays_by_sub()
    assert result["sub_1"] |> Enum.sort() == ["relay.damus.io", "relay.nostr.band"]
    assert result["sub_2"] == ["relay.damus.io"]
  end

  test "unique subscriptions flatten across relays" do
    :ok = RelayAgent.put_subscription("relay.damus.io", "sub_1", "p")
    :ok = RelayAgent.put_subscription("relay.damus.io", "sub_2", "p")
    :ok = RelayAgent.put_subscription("relay.nostr.band", "sub_1", "p")

    assert RelayAgent.get_unique_subscriptions() |> Enum.sort() == ["sub_1", "sub_2"]
  end
end
