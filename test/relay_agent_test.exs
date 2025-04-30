
defmodule Nostrbase.RelayAgentTest do
  use ExUnit.Case
  alias Nostrbase.RelayAgent

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

  test "can get relay subscriptions" do
    relay_id = "relay1"
    assert RelayAgent.get(relay_id) == nil
  end

  test "can update relay subscriptions" do
    relay_id = "relay1"
    sub_id = :test_sub
    
    assert :ok = RelayAgent.update(relay_id, sub_id)
    assert RelayAgent.get(relay_id) == [sub_id]
    
    # Adding same subscription again doesn't duplicate
    assert :ok = RelayAgent.update(relay_id, sub_id)
    assert RelayAgent.get(relay_id) == [sub_id]
  end

  test "can delete subscriptions" do
    relay_id = "relay1"
    sub_id = :test_sub
    
    RelayAgent.update(relay_id, sub_id)
    assert RelayAgent.get(relay_id) == [sub_id]
    
    RelayAgent.delete_subscription(relay_id, sub_id)
    assert RelayAgent.get(relay_id) == []
  end

  test "can delete entire relay" do
    relay_id = "relay1"
    sub_id = :test_sub
    
    RelayAgent.update(relay_id, sub_id)
    assert RelayAgent.get(relay_id) == [sub_id]
    
    RelayAgent.delete_relay(relay_id)
    assert RelayAgent.get(relay_id) == nil
  end

  test "can get relays for subscription" do
    relay1 = "relay1"
    relay2 = "relay2"
    sub_id = :test_sub
    
    RelayAgent.update(relay1, sub_id)
    RelayAgent.update(relay2, sub_id)
    
    relays = RelayAgent.get_relays_for_sub(sub_id)
    assert length(relays) == 2
    assert relay1 in relays
    assert relay2 in relays
  end
end
