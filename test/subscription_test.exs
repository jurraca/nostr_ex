defmodule NostrEx.SubscriptionTest do
  use ExUnit.Case
  alias NostrEx.Subscription
  alias Nostr.Filter

  describe "new/1" do
    test "creates subscription from single keyword list filter" do
      {:ok, sub} = Subscription.new(authors: ["abc123"], kinds: [1])

      assert %Subscription{} = sub
      assert String.length(sub.id) == 64
      assert length(sub.filters) == 1
      assert [%Filter{authors: ["abc123"], kinds: [1]}] = sub.filters
      assert is_integer(sub.created_at)
    end

    test "creates subscription from multiple keyword list filters" do
      filters = [
        [authors: ["abc123"], kinds: [1]],
        [authors: ["def456"], kinds: [0]]
      ]

      {:ok, sub} = Subscription.new(filters)

      assert %Subscription{} = sub
      assert length(sub.filters) == 2

      assert [
               %Filter{authors: ["abc123"], kinds: [1]},
               %Filter{authors: ["def456"], kinds: [0]}
             ] = sub.filters
    end

    test "creates subscription from existing Filter structs" do
      filters = [
        %Filter{authors: ["abc123"], kinds: [1]},
        %Filter{ids: ["eventid123"]}
      ]

      {:ok, sub} = Subscription.new(filters)

      assert %Subscription{} = sub
      assert length(sub.filters) == 2
      assert sub.filters == filters
    end

    test "creates subscription with empty filter list" do
      {:ok, sub} = Subscription.new([])

      assert %Subscription{} = sub
      assert sub.filters == []
    end

    test "generates unique subscription IDs" do
      {:ok, sub1} = Subscription.new(kinds: [1])
      {:ok, sub2} = Subscription.new(kinds: [1])

      refute sub1.id == sub2.id
    end

    test "returns error for invalid filter format" do
      assert {:error, _} = Subscription.new(%{not: "valid"})
      assert {:error, _} = Subscription.new("invalid")
      assert {:error, _} = Subscription.new(123)
    end

    test "returns error for mixed filter formats" do
      invalid_filters = [
        [authors: ["abc"]],
        "not a keyword list"
      ]

      assert {:error, "all filter elements must be keyword lists"} = Subscription.new(invalid_filters)
    end
  end
end
