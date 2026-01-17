defmodule NostrEx.UtilsTest do
  use ExUnit.Case
  alias NostrEx.Utils

  describe "name_from_host/1" do
    test "converts host to atom name" do
      assert :relay_example_com = Utils.name_from_host("relay.example.com")
    end

    test "handles host with trailing slash" do
      assert :relay_example_com = Utils.name_from_host("relay.example.com/")
    end

    test "handles subdomain" do
      assert :ws_relay_example_com = Utils.name_from_host("ws.relay.example.com")
    end
  end

  describe "host_from_name/1" do
    test "converts atom name to host" do
      assert "relay.example.com" = Utils.host_from_name(:relay_example_com)
    end

    test "handles binary input" do
      assert "relay.example.com" = Utils.host_from_name("relay_example_com")
    end
  end
end
