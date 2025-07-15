
defmodule NostrEx.Signer.RemoteClient do
  @moduledoc """
  NIP-46 Remote Signing client implementation.
  
  This module acts as a client that connects to remote signers
  and implements the NostrEx.Signer behaviour.
  """
  
  use GenServer
  require Logger
  
  alias Nostr.{Event, Message}
  alias NostrEx.{Client, RelayManager}
  
  @behaviour NostrEx.Signer
  
  defstruct [
    :client_keypair,
    :remote_signer_pubkey,
    :relays,
    :connection_secret,
    :user_pubkey,
    :permissions,
    :pending_requests
  ]
  
  @spec start_link(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(bunker_uri, opts \\ []) do
    case parse_bunker_uri(bunker_uri) do
      {:ok, config} ->
        GenServer.start_link(__MODULE__, config, opts)
      error ->
        error
    end
  end
  
  ## GenServer Callbacks
  
  @impl GenServer
  def init(config) do
    # Generate ephemeral client keypair
    client_private_key = :crypto.strong_rand_bytes(32)
    client_pubkey = Nostr.Keys.get_public_key(client_private_key)
    
    state = %__MODULE__{
      client_keypair: {client_private_key, client_pubkey},
      remote_signer_pubkey: config.remote_signer_pubkey,
      relays: config.relays,
      connection_secret: config.secret,
      permissions: config.permissions,
      pending_requests: %{}
    }
    
    {:ok, state, {:continue, :connect_to_relays}}
  end
  
  @impl GenServer
  def handle_continue(:connect_to_relays, state) do
    # Connect to all specified relays
    Enum.each(state.relays, fn relay_url ->
      RelayManager.connect(relay_url)
    end)
    
    # Send connect request to remote signer
    send_connect_request(state)
    {:noreply, state}
  end
  
  @impl GenServer
  def handle_call({:sign_event, event}, from, state) do
    request_id = generate_request_id()
    
    request = %{
      "id" => request_id,
      "method" => "sign_event",
      "params" => [Event.to_map(event) |> Jason.encode!()]
    }
    
    case send_encrypted_request(state, request) do
      :ok ->
        new_state = put_in(state.pending_requests[request_id], from)
        {:noreply, new_state}
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end
  
  @impl GenServer
  def handle_call({:get_pubkey}, _from, %{user_pubkey: pubkey} = state) when not is_nil(pubkey) do
    {:reply, {:ok, pubkey}, state}
  end
  
  def handle_call({:get_pubkey}, from, state) do
    request_id = generate_request_id()
    
    request = %{
      "id" => request_id,
      "method" => "get_public_key",
      "params" => []
    }
    
    case send_encrypted_request(state, request) do
      :ok ->
        new_state = put_in(state.pending_requests[request_id], from)
        {:noreply, new_state}
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end
  
  @impl GenServer
  def handle_info({:event, _sub_id, event}, state) do
    case handle_response_event(event, state) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, reason} ->
        Logger.error("NIP-46 response handling error: #{reason}")
        {:noreply, state}
    end
  end
  
  def handle_info(_msg, state), do: {:noreply, state}
  
  ## NostrEx.Signer Behaviour
  
  @impl NostrEx.Signer
  def sign_event(signer_pid, %Event{} = event) when is_pid(signer_pid) do
    GenServer.call(signer_pid, {:sign_event, event})
  end
  
  @impl NostrEx.Signer
  def get_pubkey(signer_pid) when is_pid(signer_pid) do
    GenServer.call(signer_pid, {:get_pubkey})
  end
  
  ## Private Functions
  
  defp parse_bunker_uri("bunker://" <> rest) do
    case String.split(rest, "?", parts: 2) do
      [remote_signer_pubkey, query_string] ->
        params = URI.decode_query(query_string)
        
        {:ok, %{
          remote_signer_pubkey: remote_signer_pubkey,
          relays: params["relay"] |> List.wrap(),
          secret: params["secret"],
          permissions: String.split(params["perms"] || "", ",", trim: true)
        }}
      
      [remote_signer_pubkey] ->
        {:error, "bunker URI missing relay parameters"}
      
      _ ->
        {:error, "invalid bunker URI format"}
    end
  end
  
  defp parse_bunker_uri(_), do: {:error, "URI must start with bunker://"}
  
  defp send_connect_request(state) do
    {_private_key, client_pubkey} = state.client_keypair
    
    request = %{
      "id" => generate_request_id(),
      "method" => "connect",
      "params" => [
        state.remote_signer_pubkey,
        state.connection_secret,
        Enum.join(state.permissions, ",")
      ]
    }
    
    send_encrypted_request(state, request)
  end
  
  defp send_encrypted_request(state, request) do
    {client_private_key, client_pubkey} = state.client_keypair
    
    # TODO: Implement NIP-44 encryption
    encrypted_content = encrypt_nip44(Jason.encode!(request), client_private_key, state.remote_signer_pubkey)
    
    event = Event.create(24133,
      content: encrypted_content,
      tags: [["p", state.remote_signer_pubkey]]
    )
    
    signed_event = Event.sign(event, client_private_key)
    message = Message.create_event(signed_event) |> Message.serialize()
    
    # Send to all relays
    state.relays
    |> Enum.map(&RelayManager.lookup/1)
    |> Enum.each(fn
      {:ok, pid} -> Client.send_event_serialized(pid, message)
      _ -> :ok
    end)
    
    :ok
  end
  
  defp handle_response_event(event, state) do
    case decrypt_and_parse_response(event, state) do
      {:ok, response} ->
        handle_response(response, state)
      {:error, reason} ->
        Logger.warning("Failed to decrypt NIP-46 response: #{reason}")
        {:ok, state}
    end
  end
  
  defp decrypt_and_parse_response(event, state) do
    {private_key, _} = state.client_keypair
    
    # TODO: Implement NIP-44 decryption
    case decrypt_nip44(event.content, private_key, event.pubkey) do
      {:ok, decrypted} ->
        case Jason.decode(decrypted) do
          {:ok, response} -> {:ok, response}
          _ -> {:error, "invalid JSON in decrypted content"}
        end
      error -> error
    end
  end
  
  defp handle_response(response, state) do
    request_id = response["id"]
    
    case Map.get(state.pending_requests, request_id) do
      nil ->
        {:ok, state}
      
      from ->
        result = if response["error"] do
          {:error, response["error"]}
        else
          case response["result"] do
            result when is_binary(result) ->
              # Try to parse as signed event JSON for sign_event responses
              case Jason.decode(result) do
                {:ok, event_data} -> {:ok, Event.from_map(event_data)}
                _ -> {:ok, result}
              end
            result -> {:ok, result}
          end
        end
        
        GenServer.reply(from, result)
        new_state = %{state | pending_requests: Map.delete(state.pending_requests, request_id)}
        
        # Cache user pubkey if this was a get_public_key response
        new_state = case {response["result"], String.contains?(to_string(request_id), "get_public_key")} do
          {pubkey, true} when is_binary(pubkey) -> %{new_state | user_pubkey: pubkey}
          _ -> new_state
        end
        
        {:ok, new_state}
    end
  end
  
  defp generate_request_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
  
  # Placeholder functions for NIP-44 encryption/decryption
  defp encrypt_nip44(plaintext, sender_privkey, recipient_pubkey) do
    Logger.warning("NIP-44 encryption not yet implemented, using placeholder")
    Base.encode64("PLACEHOLDER_ENCRYPTED:" <> plaintext)
  end
  
  defp decrypt_nip44(ciphertext, recipient_privkey, sender_pubkey) do
    Logger.warning("NIP-44 decryption not yet implemented, using placeholder")
    case Base.decode64(ciphertext) do
      {:ok, "PLACEHOLDER_ENCRYPTED:" <> plaintext} -> {:ok, plaintext}
      _ -> {:error, "decryption failed"}
    end
  end
end
