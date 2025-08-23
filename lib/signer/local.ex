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
  alias NostrEx.Signer

  @behaviour Signer

  defstruct [:private_key, :pubkey]

  @spec start_link(binary(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(private_key, opts \\ []) when is_binary(private_key) do
    GenServer.start_link(__MODULE__, private_key, opts)
  end

  @impl Signer
  def sign_event(signer_pid, event) do
    GenServer.call(signer_pid, {:sign_event, event})
  end

  @impl Signer
  def get_pubkey(signer_pid) do
    GenServer.call(signer_pid, :get_pubkey)
  end

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
    pubkey = Nostr.Crypto.pubkey(private_key)
    state = %__MODULE__{private_key: private_key, pubkey: pubkey}
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:sign_event, event}, _from, %{private_key: private_key} = state) do
    case sign_event_impl(private_key, event) do
      {:ok, signed_event} -> {:reply, {:ok, signed_event}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:get_pubkey, _from, %{pubkey: pubkey} = state) do
    {:reply, {:ok, pubkey}, state}
  end

  def handle_call({:ping}, _from, state) do
    {:reply, {:ok, "pong"}, state}
  end

  def handle_call({:connect, _remote_pubkey, _secret, _permissions}, _from, state) do
    # Local signer always "connects" successfully since it's local
    {:reply, {:ok, "ack"}, state}
  end

  ## Private Functions

  defp sign_event_impl(private_key, event) do
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
