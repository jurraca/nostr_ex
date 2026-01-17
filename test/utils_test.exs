defmodule NostrEx.UtilsTest do
  use ExUnit.Case
  alias NostrEx.Utils

  describe "name_from_host/1" do
    test "normalizes host to lowercase string" do
      assert "relay.example.com" = Utils.name_from_host("relay.example.com")
    end

    test "handles host with trailing slash" do
      assert "relay.example.com" = Utils.name_from_host("relay.example.com/")
    end

    test "handles subdomain" do
      assert "ws.relay.example.com" = Utils.name_from_host("ws.relay.example.com")
    end

    test "lowercases mixed case input" do
      assert "relay.example.com" = Utils.name_from_host("Relay.Example.COM")
    end
  end

  describe "host_from_name/1" do
    test "returns the relay name unchanged" do
      assert "relay.example.com" = Utils.host_from_name("relay.example.com")
    end
  end
end
