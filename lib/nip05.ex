defmodule NostrEx.Nip05 do
  @moduledoc """
  Verify DNS identifiers from profiles according to [NIP-05](https://github.com/nostr-protocol/nips/blob/master/05.md).
  """

  @doc """
  Check a NIP-05 identifier's validity on the given domain.
  """
  def verify(addr) do
    [name, domain] = String.split(addr, "@")
    query = "https://#{domain}/.well-known/nostr.json?name=#{name}"

    with {:ok, %{status: 200, body: body}} <- Req.get(query),
         %{"names" => names} = body,
         true <- name in Map.keys(names) do
      {:ok, {name, names[name]}}
    else
      false -> {:error, "Name #{name} not found on this domain"}
      {:error, %Req.TransportError{reason: :nxdomain}} -> {:error, "Domain not found: #{domain}"}
      err -> err
    end
  end
end
