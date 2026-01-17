defmodule NostrEx.Utils do
  @doc """
  Takes a host name, returns a normalized string for use as a Registry key.
  Example: "relay.damus.io" -> "relay.damus.io"
  """
  @spec name_from_host(String.t()) :: String.t()
  def name_from_host(host) when is_binary(host) do
    host
    |> String.trim("/")
    |> String.downcase()
  end

  @doc """
  Identity function for relay names (they're already hostnames).
  Kept for backwards compatibility.
  """
  @spec host_from_name(String.t()) :: String.t()
  def host_from_name(relay_name) when is_binary(relay_name) do
    relay_name
  end
end
