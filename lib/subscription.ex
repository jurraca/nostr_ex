defmodule NostrEx.Subscription do
  @moduledoc """
  Represents a Nostr subscription (REQ message).

  A subscription consists of:
  - `id` - Unique subscription identifier (generated automatically)
  - `filters` - List of `Nostr.Filter` structs defining what events to receive
  - `created_at` - Unix timestamp when the subscription was created

  ## Creating Subscriptions

      # Single filter
      {:ok, sub} = NostrEx.create_sub(authors: ["abc123"], kinds: [1])

      # Multiple filters
      {:ok, sub} = NostrEx.create_sub([
        [authors: ["abc123"], kinds: [1]],
        [authors: ["def456"], kinds: [0]]
      ])

  ## Sending Subscriptions

      {:ok, sub} = NostrEx.create_sub(authors: [pubkey], kinds: [1])
      :ok = NostrEx.send_sub(sub)
  """

  alias Nostr.Filter

  @type t :: %__MODULE__{
          id: String.t(),
          filters: [Filter.t()],
          created_at: integer()
        }

  @enforce_keys [:id, :filters, :created_at]
  defstruct [:id, :filters, :created_at]

  @doc """
  Create a new subscription with the given filters.

  Generates a unique subscription ID automatically.

  ## Parameters
  - `filters` - A keyword list for a single filter, or a list of keyword lists for multiple filters

  ## Returns
  - `{:ok, %Subscription{}}` on success
  - `{:error, reason}` if filters are invalid
  """
  @spec new(keyword() | [keyword()] | [Filter.t()]) :: {:ok, t()} | {:error, String.t()}
  def new(filters) when is_list(filters) do
    with {:ok, filter_structs} <- normalize_filters(filters) do
      sub = %__MODULE__{
        id: generate_id(),
        filters: filter_structs,
        created_at: System.os_time(:second)
      }

      {:ok, sub}
    end
  end

  def new(_), do: {:error, "filters must be a keyword list or list of keyword lists"}

  @spec normalize_filters(keyword() | [keyword()] | [Filter.t()]) ::
          {:ok, [Filter.t()]} | {:error, String.t()}
  defp normalize_filters([]), do: {:ok, []}

  defp normalize_filters([%Filter{} | _] = filters), do: {:ok, filters}

  defp normalize_filters([{_key, _value} | _] = filter) do
    filter_struct = Map.merge(%Filter{}, Enum.into(filter, %{}))
    {:ok, [filter_struct]}
  end

  defp normalize_filters([f | _] = filters) when is_list(f) do
    if Enum.all?(filters, &Keyword.keyword?/1) do
      filter_structs = Enum.map(filters, &Map.merge(%Filter{}, Enum.into(&1, %{})))
      {:ok, filter_structs}
    else
      {:error, "all filter elements must be keyword lists"}
    end
  end

  defp normalize_filters(_), do: {:error, "invalid filter format"}

  @spec generate_id() :: String.t()
  defp generate_id do
    :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
  end
end
