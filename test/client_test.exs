defmodule NostrEx.ClientTest do
  use ExUnit.Case
  alias NostrEx.Client

  @privkey "5ee1c8000ab28edd64d74a7d951af749cfb0b7e1f31a4ad87940a55b0e7e6b3d"

  describe "sign_event/2" do
    test "succeeds with private key" do
      {:ok, event} = NostrEx.create_event(1, content: "test content")
      assert {:ok, signed_event} = NostrEx.sign_event(event, @privkey)
      assert signed_event.kind == event.kind
      assert signed_event.content == event.content
      assert String.length(signed_event.sig) == 128
    end

    test "returns error for invalid signer type" do
      {:ok, event} = NostrEx.create_event(1, content: "test content")

      assert {:error, message} = Client.sign_event(event, 12345)
      assert message =~ "signer must be a binary private key"
    end
  end

  describe "sign_and_serialize/2" do
    test "signs and serializes a valid event" do
      {:ok, event} = NostrEx.create_event(1, content: "test content")
      {:ok, event_id, result} = Client.sign_and_serialize(event, @privkey)

      assert is_binary(result)

      assert ["EVENT", %{"kind" => 1, "id" => ^event_id, "content" => "test content"}] =
               JSON.decode!(result)
    end

    test "returns error for invalid event" do
      invalid_event = %{not: "an event"}

      assert {:error, "invalid event provided, must be an %Event{} struct."} =
               Client.sign_and_serialize(invalid_event, @privkey)
    end
  end

  describe "close_conn/1" do
    test "returns error for non-existent relay string" do
      assert {:error, :not_found} = Client.close_conn("non_existent_relay")
    end

    test "returns error for non-existent relay name" do
      assert {:error, :not_found} = Client.close_conn("nonexistent_relay")
    end

    test "returns error for invalid type" do
      assert {:error, :not_found} = Client.close_conn(12345)
    end
  end

  describe "sign_and_send_event/3" do
    test "returns error for invalid event" do
      invalid_event = %{not: "an event"}

      assert {:error, [{:invalid_event, "must be an %Event{} struct"}]} =
               Client.sign_and_send_event(invalid_event, @privkey, [])
    end

    test "returns error when signing fails with invalid signer" do
      {:ok, event} = NostrEx.create_event(1, content: "test content")

      assert {:error, [{:signing_failed, message}]} =
               Client.sign_and_send_event(event, 12345, [])

      assert message =~ "signer must be a binary private key"
    end
  end

  describe "send_event/2" do
    test "returns error with no relays connected" do
      {:ok, event} = NostrEx.create_event(1, content: "test content")
      {:ok, signed_event} = NostrEx.sign_event(event, @privkey)

      # With no relays connected, should return error with failures list
      assert {:error, [{:invalid_relays, message}]} = Client.send_event(signed_event)
      assert message =~ "got:"
    end

    test "returns error when invalid relay list provided" do
      {:ok, event} = NostrEx.create_event(1, content: "test content")
      {:ok, signed_event} = NostrEx.sign_event(event, @privkey)

      # Invalid relay list should return error
      assert {:error, [{:invalid_relays, _message}]} =
               Client.send_event(signed_event, send_via: ["nonexistent_relay"])
    end
  end

  describe "close_sub/1" do
    test "returns error for non-existent subscription" do
      fake_sub_id = "nonexistent_sub_id_12345"

      assert {:error, [{:not_found, message}]} = Client.close_sub(fake_sub_id)
      assert message =~ "subscription ID not found"
    end
  end

  describe "send_subscription/2" do
    test "returns error with no relays connected" do
      sub = %NostrEx.Subscription{
        id: "test_sub_id",
        filters: [%Nostr.Filter{}],
        created_at: DateTime.utc_now()
      }

      assert {:error, "no relays connected"} = Client.send_sub(sub)
    end
  end

  describe "serialize/1" do
    test "serializes a signed event to JSON" do
      {:ok, event} = NostrEx.create_event(1, content: "test content")
      {:ok, signed_event} = NostrEx.sign_event(event, @privkey)

      result = Client.serialize(signed_event)

      assert is_binary(result)
      assert ["EVENT", %{"kind" => 1, "content" => "test content"}] = JSON.decode!(result)
    end
  end
end
