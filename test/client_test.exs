defmodule Nostrbase.ClientTest do
  use ExUnit.Case
  alias Nostrbase.Client
  alias Nostr.Event

  @privkey "5ee1c8000ab28edd64d74a7d951af749cfb0b7e1f31a4ad87940a55b0e7e6b3d"

  describe "create_note/2" do
    test "creates a valid note event message" do
      note = "Hello World!"
      message = Client.create_note(note, @privkey)
      assert ["EVENT", %{"kind" => 1, "content" => ^note}] = JSON.decode!(message)
    end
  end

  describe "create_long_form/2" do
    test "creates a valid long form event message" do
      content = "# My Long Form Post\n\nThis is a test."
      message = Client.create_long_form(content, @privkey)
      assert ["EVENT", %{"kind" => 30023, "content" => ^content}] = JSON.decode!(message)
    end
  end

  describe "create_sub/1" do
    test "creates a valid subscription request" do
      filter = [authors: ["abc123"], kinds: [1]]
      {:ok, sub_id, message} = Client.create_sub(filter)

      assert ["REQ", ^sub_id, %{"authors" => ["abc123"], "kinds" => [1]}] = JSON.decode!(message)
      # 32 bytes hex encoded
      assert String.length(sub_id) == 64
    end

    test "handles multiple filters" do
      filters = [
        [authors: ["abc123"], kinds: [1]],
        [authors: ["def456"], kinds: [2]]
      ]

      {:ok, sub_id, message} = Client.create_sub(filters)

      assert [
               "REQ",
               ^sub_id,
               %{"authors" => ["abc123"], "kinds" => [1]},
               %{"authors" => ["def456"], "kinds" => [2]}
             ] = JSON.decode!(message)
    end

    test "returns error for invalid filter format" do
      invalid_filter = %{invalid: "format"}
      assert {:error, "Invalid filter format"} = Client.create_sub(invalid_filter)
    end
  end

  describe "sign_and_serialize/2" do
    test "signs and serializes a valid event" do
      event = Event.create(1, content: "test content")
      result = Client.sign_and_serialize(event, @privkey)
      
      assert is_binary(result)
      assert ["EVENT", %{"kind" => 1, "content" => "test content"}] = JSON.decode!(result)
    end

    test "returns error for invalid event" do
      invalid_event = %{not: "an event"}
      assert {:error, "invalid event provided, must be an %Event{} struct."} = 
        Client.sign_and_serialize(invalid_event, @privkey)
    end
  end

  describe "subscribe/3" do
    test "returns error for invalid sub_id format" do
      assert {:error, "invalid sub_id format, got 123"} = 
        Client.subscribe("relay_name", 123, "payload")
    end
  end

  describe "close_sub/1" do
  end

  describe "close_conn/1" do
    test "returns error for non-existent relay" do
      assert {:error, :not_found} = Client.close_conn("non_existent_relay")
    end
  end
end
