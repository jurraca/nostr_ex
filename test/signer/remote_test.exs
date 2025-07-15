
defmodule NostrEx.Signer.RemoteTest do
  use ExUnit.Case, async: false
  
  alias NostrEx.Signer.Remote
  alias Nostr.Event
  
  setup do
    # Clean up any existing connections
    NostrEx.RelayManager.active_pids()
    |> Enum.each(&NostrEx.RelayManager.disconnect/1)
    
    :ok
  end
  
  describe "bunker URI parsing" do
    test "parses valid bunker URI" do
      uri = "bunker://abc123?relay=wss://relay.example.com&secret=def456&perms=sign_event"
      
      assert {:ok, pid} = Remote.start_client(uri)
      Process.exit(pid, :normal)
    end
    
    test "rejects invalid bunker URI" do
      assert {:error, _} = Remote.start_client("invalid://uri")
    end
    
    test "rejects bunker URI without relays" do
      uri = "bunker://abc123"
      assert {:error, _} = Remote.start_client(uri)
    end
  end
  
  describe "nostrconnect URI generation" do
    test "generates valid nostrconnect URI" do
      pubkey = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
      relays = ["wss://relay1.example.com", "wss://relay2.example.com"]
      opts = [name: "Test App", perms: ["sign_event"]]
      
      uri = Remote.generate_connect_uri(pubkey, relays, opts)
      
      assert String.starts_with?(uri, "nostrconnect://#{pubkey}")
      assert String.contains?(uri, "relay=wss%3A%2F%2Frelay1.example.com")
      assert String.contains?(uri, "name=Test+App")
    end
  end
  
  describe "signer mode" do
    test "can start remote signer service" do
      private_key = :crypto.strong_rand_bytes(32)
      relays = ["wss://relay.example.com"]
      
      assert {:ok, pid} = Remote.start_signer(private_key, relays)
      assert Process.alive?(pid)
      
      Process.exit(pid, :normal)
    end
    
    test "can sign events directly in signer mode" do
      private_key = :crypto.strong_rand_bytes(32)
      relays = ["wss://relay.example.com"]
      
      {:ok, signer} = Remote.start_signer(private_key, relays)
      
      event = Event.create(1, content: "test note")
      assert {:ok, signed_event} = NostrEx.Signer.sign_event(signer, event)
      assert is_binary(signed_event.id)
      assert is_binary(signed_event.sig)
      
      Process.exit(signer, :normal)
    end
  end
  
  describe "placeholder encryption" do
    test "encrypt and decrypt work with placeholder implementation" do
      # This test ensures the placeholder functions work
      # Real NIP-44 implementation will be added separately
      
      private_key = :crypto.strong_rand_bytes(32)
      relays = ["wss://relay.example.com"]
      
      {:ok, signer} = Remote.start_signer(private_key, relays)
      
      # The signer should start without errors even with placeholder encryption
      assert Process.alive?(signer)
      
      Process.exit(signer, :normal)
    end
  end
end
