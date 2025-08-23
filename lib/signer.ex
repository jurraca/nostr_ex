defmodule NostrEx.Signer do
  @moduledoc """
  Behaviour for signing Nostr events.
  """

  alias Nostr.Event

  @doc """
  Sign a Nostr event.

  Returns the signed event with id and sig fields populated.
  """
  @callback sign_event(pid() | atom(), Event.t()) :: {:ok, Event.t()} | {:error, String.t()}

  @doc """
  Get the public key for this signer.
  """
  @callback get_pubkey(pid() | atom()) :: {:ok, binary()} | {:error, String.t()}
end
