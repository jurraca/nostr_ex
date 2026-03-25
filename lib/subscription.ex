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
    case normalize_filters(filters) do
      {:ok, filter_structs} ->
        sub = %__MODULE__{
          id: generate_id(),
          filters: filter_structs,
          created_at: DateTime.utc_now()
        }
  
        {:ok, sub}
      {:error, reason} -> {:error, reason}
    end
  end

  def new(%Filter{} = filter) do
      sub = %__MODULE__{
        id: generate_id(),
        filters: [filter],
        created_at: DateTime.utc_now()
      }

      {:ok, sub}
  end

  def new(_), do: {:error, "filters must be a keyword list or list of keyword lists"}

  @spec normalize_filters(keyword() | [keyword()] | [Filter.t()]) ::
          {:ok, [Filter.t()]} | {:error, String.t()}
  defp normalize_filters([]), do: {:ok, []}
  defp normalize_filters(filter) when is_map(filter), do: {:ok, parse_filter(filter)}

  defp normalize_filters([%Filter{} | _] = filters) do
    if Enum.all?(filters, &is_struct(&1, Filter)) do
      {:ok, filters}
    else
      {:error, "mixed filter types provided"}
    end
  end

  defp normalize_filters([f | _] = filters) when is_list(f) do
    if Enum.all?(filters, &(Keyword.keyword?(&1) || is_map(&1))) do
      filter_structs = Enum.map(filters, &parse_filter/1)
      {:ok, filter_structs}
    else
      {:error, "all filter elements must be keyword lists or maps"}
    end
  end

  defp normalize_filters(filter) when is_list(filter) do
    if Keyword.keyword?(filter) do
      {:ok, [parse_filter(filter)]}
    else
      {:error, "invalid filter format"}
    end
  end

  defp normalize_filters(_), do: {:error, "invalid filter format"}

  defp parse_filter(filter) when is_list(filter) do
    filter |> Enum.into(%{}) |> Filter.parse()
  end

  @spec generate_id() :: String.t()
  defp generate_id do
    :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
  end
end
