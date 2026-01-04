defmodule NostrEx.Signer.LocalTest do
  use ExUnit.Case, async: true
  
  import ExUnit.CaptureLog

  alias NostrEx.Signer.Local
  alias Nostr.Event
  
  @private_key "5ee1c8000ab28edd64d74a7d951af749cfb0b7e1f31a4ad87940a55b0e7e6b3d"
  @expected_pubkey "d5659c8123bd7f15149bbf6a5772ce49af1ec280dff3d68e7e00359a4df1b9a5"
  
  setup_all do
    {:ok, signer_pid} = Local.start_link(@private_key)
    
    on_exit(fn ->
      GenServer.stop(signer_pid)
    end)
    
    %{signer_pid: signer_pid}
  end
  
  describe "GenServer interface" do
    test "start_link/2 starts a local signer process" do
      assert {:ok, pid} = Local.start_link(@private_key)
      assert Process.alive?(pid)
      
      GenServer.stop(pid)
    end
    
    test "sign_event/2 signs events using GenServer", %{signer_pid: signer_pid} do
      event = Event.create(1, content: "test note")
      
      assert {:ok, signed_event} = Local.sign_event(signer_pid, event)
      assert is_binary(signed_event.id)
      assert is_binary(signed_event.sig)
      assert signed_event.content == "test note"
      assert signed_event.kind == 1
      assert signed_event.pubkey == @expected_pubkey
    end
    
    test "get_pubkey/1 returns public key from GenServer", %{signer_pid: signer_pid} do
      assert {:ok, pubkey} = Local.get_pubkey(signer_pid)
      assert pubkey == @expected_pubkey
    end
    
    test "ping/1 returns pong", %{signer_pid: signer_pid} do
      assert {:ok, "pong"} = Local.ping(signer_pid)
    end
    
    test "connect/4 always returns ack for local signer", %{signer_pid: signer_pid} do
      remote_pubkey = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
      
      assert {:ok, "ack"} = Local.connect(signer_pid, remote_pubkey, "secret", ["sign_event"])
    end
    
    test "can start with custom GenServer options" do
      opts = [name: :test_signer]
      assert {:ok, pid} = Local.start_link(@private_key, opts)
      assert Process.whereis(:test_signer) == pid
      
      GenServer.stop(pid)
    end
    
    test "handles signing errors gracefully", %{signer_pid: signer_pid} do
      event = Event.create(1, content: "test")
      invalid_event = %Event{event | id: "invalid"}
      
      {result, log} = with_log(fn -> Local.sign_event(signer_pid, invalid_event) end)
      assert {:error, "Failed to sign event: Event ID isn't correct"} = result
      assert log =~ "Event ID isn't correct"
    end
  end
end
