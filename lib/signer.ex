
defmodule NostrEx.Signer do
  @moduledoc """
  Behaviour for signing Nostr events.
  
  This allows for different signing implementations:
  - Direct private key signing
  - Hardware wallet signing
  - Remote signing services
  - Key derivation from seed phrases
  """
  
  alias Nostr.Event
  
  @doc """
  Sign a Nostr event.
  
  Returns the signed event with id and sig fields populated.
  """
  @callback sign_event(Event.t()) :: {:ok, Event.t()} | {:error, String.t()}
  
  @doc """
  Get the public key for this signer.
  """
  @callback get_pubkey() :: {:ok, binary()} | {:error, String.t()}
end

defmodule NostrEx.Signer.PrivateKey do
  @moduledoc """
  Simple private key signer implementation.
  """
  
  @behaviour NostrEx.Signer
  
  alias Nostr.Event
  
  defstruct [:private_key]
  
  @spec new(binary()) :: %__MODULE__{}
  def new(private_key) when is_binary(private_key) do
    %__MODULE__{private_key: private_key}
  end
  
  @impl NostrEx.Signer
  def sign_event(%__MODULE__{private_key: private_key}, %Event{} = event) do
    try do
      signed_event = Event.sign(event, private_key)
      {:ok, signed_event}
    rescue
      _ -> {:error, "Failed to sign event"}
    end
  end
  
  @impl NostrEx.Signer
  def get_pubkey(%__MODULE__{private_key: private_key}) do
    try do
      pubkey = Nostr.Keys.get_public_key(private_key)
      {:ok, pubkey}
    rescue
      _ -> {:error, "Failed to derive public key"}
    end
  end
end
