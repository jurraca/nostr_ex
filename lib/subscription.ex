defmodule NostrEx.Subscription do
  @moduledoc """
  Represents a Nostr subscription (REQ message).

  A subscription consists of:
  - `id` - Unique subscription identifier (generated automatically)
  - `filters` - List of `NostrCore.Filter` structs defining what events to receive
  - `created_at` - Timestamp when the subscription was created

  ## Creating Subscriptions

      # Single filter
      {:ok, sub} = NostrEx.create_sub(authors: ["abc123"], kinds: [1])

      # Multiple filters
      {:ok, sub} = NostrEx.create_sub([
        [authors: ["abc123"], kinds: [1]],
        [authors: ["def456"], kinds: [0]]
      ])
  """

  alias NostrCore.Filter

  @type t :: %__MODULE__{
          id: String.t(),
          filters: [Filter.t()],
          created_at: DateTime.t()
        }

  @enforce_keys [:id, :filters, :created_at]
  defstruct [:id, :filters, :created_at]

  @type filter_input :: keyword() | map() | Filter.t()
  @type filters_input :: filter_input() | [filter_input()]

  @doc """
  Create a new subscription with the given filters.

  Accepts a single keyword-list/map/`NostrCore.Filter` or a list of those.

  ## Returns
  - `{:ok, %Subscription{}}` on success
  - `{:error, reason}` if filters are invalid
  """
  @spec new(filters_input()) :: {:ok, t()} | {:error, String.t()}
  def new(%Filter{} = filter), do: build([filter])

  def new(filters) when is_list(filters) do
    case normalize_filters(filters) do
      {:ok, filter_structs} -> build(filter_structs)
      {:error, reason} -> {:error, reason}
    end
  end

  def new(filter) when is_map(filter) do
    case parse_filter(filter) do
      {:ok, parsed} -> build([parsed])
      {:error, reason} -> {:error, format_filter_error(reason)}
    end
  end

  def new(_),
    do: {:error, "filters must be a keyword list, map, Filter struct, or list of filters"}

  @spec normalize_filters(keyword() | [filter_input()]) ::
          {:ok, [Filter.t()]} | {:error, String.t()}
  defp normalize_filters([]), do: {:ok, []}

  defp normalize_filters(filter) when is_list(filter) do
    cond do
      Keyword.keyword?(filter) ->
        parse_one_filter(filter)

      Enum.all?(filter, &filter_input?/1) ->
        filter
        |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
          case parse_filter(item) do
            {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
            {:error, reason} -> {:halt, {:error, format_filter_error(reason)}}
          end
        end)
        |> case do
          {:ok, filters} -> {:ok, Enum.reverse(filters)}
          error -> error
        end

      true ->
        {:error, "all filter elements must be keyword lists, maps, or Filter structs"}
    end
  end

  defp parse_one_filter(filter) do
    case parse_filter(filter) do
      {:ok, parsed} -> {:ok, [parsed]}
      {:error, reason} -> {:error, format_filter_error(reason)}
    end
  end

  defp filter_input?(%Filter{}), do: true
  defp filter_input?(value) when is_map(value), do: true
  defp filter_input?(value) when is_list(value), do: Keyword.keyword?(value)
  defp filter_input?(_), do: false

  defp parse_filter(%Filter{} = filter), do: {:ok, filter}

  defp parse_filter(filter) when is_map(filter) do
    if valid_filter_keys?(filter), do: Filter.parse(filter), else: {:error, :invalid_filter}
  end

  defp parse_filter(filter) when is_list(filter) do
    if valid_filter_keys?(filter), do: Filter.parse(filter), else: {:error, :invalid_filter}
  end

  defp parse_filter(_), do: {:error, :invalid_filter}

  defp valid_filter_keys?(filter) do
    Enum.any?(filter, fn {key, _value} -> valid_filter_key?(key) end)
  end

  defp valid_filter_key?(key) when is_atom(key),
    do: key |> Atom.to_string() |> valid_filter_key?()

  defp valid_filter_key?(key) when is_binary(key) do
    key in ["ids", "authors", "kinds", "since", "until", "limit", "search"] or
      Regex.match?(~r/^#[a-zA-Z]$/, key)
  end

  defp valid_filter_key?(_), do: false

  defp build(filters) do
    {:ok,
     %__MODULE__{
       id: generate_id(),
       filters: filters,
       created_at: DateTime.utc_now()
     }}
  end

  defp format_filter_error({:invalid_field, field}), do: "invalid filter field: #{field}"
  defp format_filter_error({:invalid_tag_filter, tag}), do: "invalid tag filter: #{tag}"
  defp format_filter_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_filter_error(reason), do: inspect(reason)

  @spec generate_id() :: String.t()
  defp generate_id do
    :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
  end
end
