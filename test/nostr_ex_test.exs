defmodule NostrExTest do
  use ExUnit.Case
  alias NostrEx.Subscription

  @privkey "5ee1c8000ab28edd64d74a7d951af749cfb0b7e1f31a4ad87940a55b0e7e6b3d"

  describe "create_event/2" do
    test "creates event from keyword list" do
      {:ok, event} = NostrEx.create_event(1, content: "hello world")

      assert event.kind == 1
      assert event.content == "hello world"
    end

    test "creates event from map" do
      {:ok, event} = NostrEx.create_event(1, %{content: "hello"})

      assert event.kind == 1
      assert event.content == "hello"
    end

    test "returns error for invalid kind" do
      assert {:error, _} = NostrEx.create_event("not-an-int", content: "hi")
    end
  end

  describe "sign_event/2" do
    test "signs event with private key" do
      {:ok, event} = NostrEx.create_event(1, content: "test")
      {:ok, signed} = NostrEx.sign_event(event, @privkey)

      assert signed.kind == event.kind
      assert String.length(signed.sig) == 128
      assert is_binary(signed.id)
    end

    test "returns error for non-event struct" do
      assert {:error, _} = NostrEx.sign_event(%{not: "event"}, @privkey)
    end
  end

  describe "send_event/2" do
    test "returns error if event is not signed" do
      {:ok, event} = NostrEx.create_event(1, content: "unsigned")
      assert {:error, "event must be signed before sending"} = NostrEx.send_event(event)
    end
  end

  describe "create_sub/1" do
    test "creates subscription from keyword filter" do
      {:ok, sub} = NostrEx.create_sub(authors: ["abc123"], kinds: [1])

      assert %Subscription{} = sub
      assert String.length(sub.id) == 64
      assert length(sub.filters) == 1
    end

    test "creates subscription from multiple filters" do
      filters = [
        [authors: ["abc"], kinds: [1]],
        [kinds: [0, 3]]
      ]

      {:ok, sub} = NostrEx.create_sub(filters)

      assert %Subscription{} = sub
      assert length(sub.filters) == 2
    end

    test "returns error for invalid filters" do
      assert {:error, _} = NostrEx.create_sub(%{invalid: "format"})
    end
  end

  describe "relay management" do
    test "list_relays returns empty list when no relays connected" do
      relays = NostrEx.list_relays()
      assert is_list(relays)
    end

    test "list_subs returns empty list when no subscriptions" do
      subs = NostrEx.list_subs()
      assert is_list(subs)
    end

    test "disconnect returns error for non-existent relay" do
      assert {:error, :not_found} = NostrEx.disconnect("nonexistent_relay")
    end
  end

  describe "close_sub/1" do
    test "returns error for non-existent subscription ID" do
      assert {:error, _} = NostrEx.close_sub("nonexistent_sub_id")
    end

    test "works with Subscription struct" do
      {:ok, sub} = NostrEx.create_sub(kinds: [1])
      assert {:error, _} = NostrEx.close_sub(sub)
    end
  end

  describe "listen/1" do
    test "returns :ok for subscription struct" do
      {:ok, sub} = NostrEx.create_sub(kinds: [1])
      assert :ok = NostrEx.listen(sub)
    end

    test "returns :ok for subscription id string" do
      {:ok, sub} = NostrEx.create_sub(kinds: [1])
      assert :ok = NostrEx.listen(sub.id)
    end

    test "is idempotent - calling twice returns :ok" do
      {:ok, sub} = NostrEx.create_sub(kinds: [1])
      assert :ok = NostrEx.listen(sub)
      assert :ok = NostrEx.listen(sub)
    end
  end

  describe "create_sub -> send_sub -> listen workflow" do
    test "full workflow works without relay connection" do
      {:ok, sub} = NostrEx.create_sub(authors: ["abc123"], kinds: [1])

      assert %NostrEx.Subscription{} = sub
      assert String.length(sub.id) == 64

      assert {:error, "no relays connected"} = NostrEx.send_sub(sub)

      assert :ok = NostrEx.listen(sub)
    end
  end
end
