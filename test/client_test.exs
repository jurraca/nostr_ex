defmodule NostrEx.ClientTest do
  use ExUnit.Case
  alias NostrEx.Client

  @privkey "5ee1c8000ab28edd64d74a7d951af749cfb0b7e1f31a4ad87940a55b0e7e6b3d"

  describe "sign event" do
    test "succeeds with private key" do
      {:ok, event} = NostrEx.create_event(1, content: "test content")
      assert {:ok, signed_event} = NostrEx.sign_event(event, @privkey)
      assert signed_event.kind == event.kind
      assert signed_event.content == event.content
      assert String.length(signed_event.sig) == 128
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
    test "returns error for non-existent relay" do
      assert {:error, :not_found} = Client.close_conn("non_existent_relay")
    end
  end

  describe "sign_and_send_event/3" do
    test "returns error for invalid event" do
      invalid_event = %{not: "an event"}

      assert {:error, [{:invalid_event, "must be an %Event{} struct"}]} =
               Client.sign_and_send_event(invalid_event, @privkey, [])
    end
  end
end
