defmodule Nostrbase.ClientTest do
  use ExUnit.Case
  alias Nostrbase.Client

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
      assert ["EVENT", %{"kind" => 23, "content" => ^content}] = JSON.decode!(message)
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
  end
end
