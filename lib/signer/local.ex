defmodule NostrEx.Signer.Local do
  @moduledoc """
  Local signer that mimics the NIP-46 interface but keeps private keys in memory.

  This is the simplest and most secure option for single-user applications
  where you want to keep your private key local to your application while
  maintaining compatibility with the NIP-46 interface.
  """

  use GenServer
  require Logger

  alias Nostr.Event

  @behaviour NostrEx.Signer

  defstruct [:private_key, :pubkey]

  @spec start_link(binary(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(private_key, opts \\ []) when is_binary(private_key) do
    GenServer.start_link(__MODULE__, private_key, opts)
  end

  @spec new(binary()) :: %__MODULE__{}
  def new(private_key) when is_binary(private_key) do
    pubkey = Nostr.Keys.get_public_key(private_key)
    %__MODULE__{private_key: private_key, pubkey: pubkey}
  end

  ## NostrEx.Signer Behaviour - Direct struct interface

  @impl NostrEx.Signer
  def sign_event(%__MODULE__{} = signer, event) do
    sign_event_impl(signer, event)
  end

  @impl NostrEx.Signer
  def get_pubkey(%__MODULE__{pubkey: pubkey}), do: {:ok, pubkey}

  ## NostrEx.Signer Behaviour - GenServer interface

  def sign_event(signer_pid, event) when is_pid(signer_pid) do
    GenServer.call(signer_pid, {:sign_event, event})
  end

  def get_pubkey(signer_pid) when is_pid(signer_pid) do
    GenServer.call(signer_pid, {:get_pubkey})
  end

  ## NIP-46-like interface for compatibility

  @spec ping(pid()) :: {:ok, String.t()}
  def ping(signer_pid) when is_pid(signer_pid) do
    GenServer.call(signer_pid, {:ping})
  end

  @spec connect(pid(), binary(), binary() | nil, [String.t()]) :: {:ok, String.t()}
  def connect(signer_pid, remote_pubkey, secret \\ nil, permissions \\ [])
      when is_pid(signer_pid) do
    GenServer.call(signer_pid, {:connect, remote_pubkey, secret, permissions})
  end

  ## GenServer Callbacks

  @impl GenServer
  def init(private_key) do
    pubkey = Nostr.Keys.get_public_key(private_key)
    state = %__MODULE__{private_key: private_key, pubkey: pubkey}
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:sign_event, event}, _from, state) do
    case sign_event_impl(state, event) do
      {:ok, signed_event} -> {:reply, {:ok, signed_event}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:get_pubkey}, _from, state) do
    {:reply, {:ok, state.pubkey}, state}
  end

  def handle_call({:ping}, _from, state) do
    {:reply, {:ok, "pong"}, state}
  end

  def handle_call({:connect, _remote_pubkey, _secret, _permissions}, _from, state) do
    # Local signer always "connects" successfully since it's local
    {:reply, {:ok, "ack"}, state}
  end

  ## Private Functions

  defp sign_event_impl(%__MODULE__{private_key: private_key}, event) do
    try do
      signed_event = Event.sign(event, private_key)
      {:ok, signed_event}
    rescue
      error ->
        Logger.error("Failed to sign event: #{inspect(error)}")
        {:error, "Failed to sign event"}
    end
  end
end
