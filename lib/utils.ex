defmodule NostrEx.Utils do
  @doc """
  Aggregates a list of :ok / :error tuples into a single tuple.
  """
  def collect(results) do
    {oks, errors} = Enum.split_with(results, &match?({:ok, _}, &1))

    case errors do
      [] -> {:ok, Enum.map(oks, fn {:ok, v} -> v end)}
      errors -> {:error, errors |> Enum.reject(&is_nil/1) |> Enum.map(fn {:error, e} -> e end)}
    end
  end

  @doc """
  Takes a host name, returns an atom representation for use as human-readable reference, e.g. "relay_mysite_com".
  """
  def name_from_host(host) when is_binary(host) do
    host
    |> String.trim("/")
    |> String.replace(".", "_")
    |> String.to_atom()
  end

  @doc """
  Takes an atom name, returns a hostname which should match the initial host name parsed from the relay URL.
  """
  def host_from_name(relay_name) when is_atom(relay_name) do
    relay_name
    |> Atom.to_string()
    |> String.replace("_", ".")
  end

  def host_from_name(relay_name) when is_binary(relay_name) do
    String.to_atom(relay_name) |> host_from_name()
  end
end
