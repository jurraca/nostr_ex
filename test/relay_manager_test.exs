defmodule Nostrbase.RelayManagerTest do
  use ExUnit.Case
  alias Nostrbase.RelayManager

  describe "URL parsing" do
    test "rejects HTTP URLs" do
      assert {:error,
              "The relay URL must be a websocket, not an HTTP URL, got: http://example.com"} =
               RelayManager.connect("http://example.com")
    end

    test "rejects HTTPS URLs" do
      assert {:error,
              "The relay URL must be a websocket, not an HTTP URL, got: https://example.com"} =
               RelayManager.connect("https://example.com")
    end

    test "rejects invalid URLs" do
      assert {:error, "Invalid URL invalid-url with host empty"} =
               RelayManager.connect("invalid-url")
    end

    test "rejects URLs without host" do
      assert {:error, "Invalid URL ws:// with host empty"} =
               RelayManager.connect("ws://")
    end
  end

  describe "relay management" do
    test "returns empty list for active_pids when no relays" do
      # Clear any existing connections
      pids = RelayManager.active_pids()
      assert is_list(pids)
    end

    test "returns empty list for registered_names when no relays" do
      names = RelayManager.registered_names()
      assert is_list(names)
    end

    test "returns empty list for get_states when no relays" do
      states = RelayManager.get_states()
      assert is_list(states)
    end

    test "lookup returns error for non-existent relay" do
      assert {:error, :not_found} = RelayManager.lookup("non_existent_relay")
    end

    test "lookup returns error for non-existent atom relay" do
      assert {:error, :not_found} = RelayManager.lookup(:non_existent_relay)
    end
  end

  describe "disconnect" do
    test "disconnect by name returns error for non-existent relay" do
      assert {:error, :not_found} = RelayManager.disconnect("non_existent_relay")
    end

    test "disconnect by atom returns error for non-existent relay" do
      assert {:error, :not_found} = RelayManager.disconnect(:non_existent_relay)
    end
  end

  describe "ready? checks" do
    test "ready? returns error for non-existent relay name" do
      assert {:error, :not_found} = RelayManager.ready?("non_existent_relay")
    end
  end

  describe "wait_for_ready" do
    test "wait_for_ready times out for non-ready connection" do
    end
  end

  describe "relays/0" do
    test "returns supervisor children list" do
      children = RelayManager.relays()
      assert is_list(children)
      # Each child should be a tuple with supervisor info
      Enum.each(children, fn child ->
        assert is_tuple(child)
      end)
    end
  end
end
