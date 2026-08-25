defmodule NostrEx.Backoff do
  @moduledoc """
  Full-jitter exponential backoff.

  The delay for attempt N (1-based) is drawn uniformly from
  `1..min(max, base * 2^(N-1))`, which spreads reconnect storms across
  clients while still backing off hard on persistent failures.
  """

  @default_min 500
  @default_max 30_000

  @spec next_delay(pos_integer(), keyword()) :: pos_integer()
  def next_delay(attempt, opts \\ []) when is_integer(attempt) and attempt >= 1 do
    base = Keyword.get(opts, :min, @default_min)
    ceiling = Keyword.get(opts, :max, @default_max)

    cap = max(base, min(ceiling, base * 2 ** (attempt - 1)))
    :rand.uniform(cap)
  end
end
