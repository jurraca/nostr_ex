defmodule NostrEx.BackoffTest do
  use ExUnit.Case, async: true

  alias NostrEx.Backoff

  test "attempt 1 delay is within the base window" do
    for _ <- 1..200 do
      assert Backoff.next_delay(1) in 1..500
    end
  end

  test "delay cap grows exponentially and clamps at max" do
    # attempt 4: 500 * 2^3 = 4000 (below the default max)
    for _ <- 1..200 do
      assert Backoff.next_delay(4) in 1..4000
    end

    # attempt 10: 500 * 2^9 = 256_000 -> clamped to 30s
    for _ <- 1..200 do
      assert Backoff.next_delay(10) in 1..30_000
    end
  end

  test "custom bounds are respected" do
    for _ <- 1..200 do
      assert Backoff.next_delay(1, min: 20, max: 50) in 1..20
      assert Backoff.next_delay(3, min: 20, max: 50) in 1..50
      assert Backoff.next_delay(5, min: 100, max: 1000) in 1..1000
    end
  end

  test "delays vary (jitter), not a fixed schedule" do
    delays = for _ <- 1..50, do: Backoff.next_delay(2)
    assert Enum.uniq(delays) |> length() > 5
  end
end
