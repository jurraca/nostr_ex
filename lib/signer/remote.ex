
defmodule NostrEx.Signer.Remote do
  @moduledoc """
  NIP-46 Remote Signing implementation.
  
  This module can act as both a remote signer and a client connecting to remote signers.
  It implements the NIP-46 protocol for secure remote event signing over Nostr relays.
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
    :name,
    :url,
    :image,
    :pending_requests,
    :mode
  ]
  
  # Client mode - connects to a remote signer
  @spec start_client(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_client(bunker_uri, opts \\ []) do
    case parse_bunker_uri(bunker_uri) do
      {:ok, config} ->
        GenServer.start_link(__MODULE__, {:client, config}, opts)
      error ->
        error
    end
  end
  
  # Signer mode - acts as a remote signer service
  @spec start_signer(binary(), [String.t()], keyword()) :: {:ok, pid()} | {:error, term()}
  def start_signer(private_key, relay_urls, opts \\ []) when is_binary(private_key) do
    config = %{
      private_key: private_key,
      relay_urls: relay_urls,
      permissions: opts[:permissions] || []
    }
    GenServer.start_link(__MODULE__, {:signer, config}, opts)
  end
  
  # Generate a nostrconnect:// URI for client-initiated connections
  @spec generate_connect_uri(binary(), [String.t()], keyword()) :: String.t()
  def generate_connect_uri(client_pubkey, relay_urls, opts \\ []) do
    params = %{
      "relay" => relay_urls,
      "secret" => :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower),
      "perms" => Enum.join(opts[:permissions] || [], ","),
      "name" => opts[:name] || "NostrEx Client",
      "url" => opts[:url],
      "image" => opts[:image]
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> URI.encode_query()
    
    "nostrconnect://#{client_pubkey}?#{params}"
  end
  
  ## GenServer Callbacks
  
  @impl GenServer
  def init({:client, config}) do
    # Generate ephemeral client keypair
    client_private_key = :crypto.strong_rand_bytes(32)
    client_pubkey = Nostr.Keys.get_public_key(client_private_key)
    
    state = %__MODULE__{
      mode: :client,
      client_keypair: {client_private_key, client_pubkey},
      remote_signer_pubkey: config.remote_signer_pubkey,
      relays: config.relays,
      connection_secret: config.secret,
      permissions: config.permissions,
      pending_requests: %{}
    }
    
    # Connect to relays and send connect request
    {:ok, state, {:continue, :connect_to_relays}}
  end
  
  def init({:signer, config}) do
    signer_pubkey = Nostr.Keys.get_public_key(config.private_key)
    
    state = %__MODULE__{
      mode: :signer,
      client_keypair: {config.private_key, signer_pubkey},
      relays: config.relay_urls,
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
    
    case state.mode do
      :client ->
        # Send connect request to remote signer
        send_connect_request(state)
      :signer ->
        # Subscribe to incoming requests
        subscribe_to_requests(state)
    end
    
    {:noreply, state}
  end
  
  @impl GenServer
  def handle_call({:sign_event, event}, from, %{mode: :client} = state) do
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
  
  def handle_call({:get_pubkey}, _from, %{user_pubkey: pubkey} = state) when not is_nil(pubkey) do
    {:reply, {:ok, pubkey}, state}
  end
  
  def handle_call({:get_pubkey}, from, %{mode: :client} = state) do
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
    case handle_nip46_event(event, state) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, reason} ->
        Logger.error("NIP-46 event handling error: #{reason}")
        {:noreply, state}
    end
  end
  
  def handle_info(_msg, state), do: {:noreply, state}
  
  ## NostrEx.Signer Behaviour
  
  @impl NostrEx.Signer
  def sign_event(%{mode: :client} = signer, %Event{} = event) do
    GenServer.call(signer, {:sign_event, event})
  end
  
  def sign_event(%{mode: :signer, client_keypair: {private_key, _}}, %Event{} = event) do
    # In signer mode, sign directly with the stored private key
    try do
      signed_event = Event.sign(event, private_key)
      {:ok, signed_event}
    rescue
      _ -> {:error, "Failed to sign event"}
    end
  end
  
  @impl NostrEx.Signer
  def get_pubkey(%{mode: :client} = signer) do
    GenServer.call(signer, {:get_pubkey})
  end
  
  def get_pubkey(%{mode: :signer, client_keypair: {_, pubkey}}) do
    {:ok, pubkey}
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
  
  defp subscribe_to_requests(state) do
    {_private_key, signer_pubkey} = state.client_keypair
    
    # Subscribe to events tagged to this signer
    filter = [p: [signer_pubkey], kinds: [24133]]
    Client.send_sub(filter)
  end
  
  defp send_encrypted_request(state, request) do
    {client_private_key, client_pubkey} = state.client_keypair
    
    # TODO: Implement NIP-44 encryption
    # For now, we'll use a placeholder
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
  
  defp handle_nip46_event(event, state) do
    case decrypt_and_parse_request(event, state) do
      {:ok, request} ->
        handle_nip46_request(request, event, state)
      {:error, reason} ->
        Logger.warning("Failed to decrypt NIP-46 message: #{reason}")
        {:ok, state}
    end
  end
  
  defp decrypt_and_parse_request(event, state) do
    {private_key, _} = state.client_keypair
    
    # TODO: Implement NIP-44 decryption
    # For now, return a placeholder
    case decrypt_nip44(event.content, private_key, event.pubkey) do
      {:ok, decrypted} ->
        case Jason.decode(decrypted) do
          {:ok, request} -> {:ok, request}
          _ -> {:error, "invalid JSON in decrypted content"}
        end
      error -> error
    end
  end
  
  defp handle_nip46_request(request, original_event, state) do
    case {request["method"], state.mode} do
      {"connect", :signer} ->
        handle_connect_request(request, original_event, state)
      
      {"sign_event", :signer} ->
        handle_sign_event_request(request, original_event, state)
      
      {"get_public_key", :signer} ->
        handle_get_pubkey_request(request, original_event, state)
      
      {_method, :client} ->
        handle_response(request, state)
      
      _ ->
        {:ok, state}
    end
  end
  
  defp handle_connect_request(request, original_event, state) do
    # Validate connection request and send response
    response = %{
      "id" => request["id"],
      "result" => "ack",
      "error" => nil
    }
    
    send_encrypted_response(response, original_event.pubkey, state)
    {:ok, state}
  end
  
  defp handle_sign_event_request(request, original_event, state) do
    [event_json] = request["params"]
    
    case Jason.decode(event_json) do
      {:ok, event_data} ->
        event = Event.from_map(event_data)
        {private_key, _} = state.client_keypair
        
        case Event.sign(event, private_key) do
          signed_event ->
            response = %{
              "id" => request["id"],
              "result" => Jason.encode!(Event.to_map(signed_event)),
              "error" => nil
            }
            
            send_encrypted_response(response, original_event.pubkey, state)
            {:ok, state}
        end
      
      _ ->
        error_response = %{
          "id" => request["id"],
          "result" => nil,
          "error" => "invalid event format"
        }
        
        send_encrypted_response(error_response, original_event.pubkey, state)
        {:ok, state}
    end
  end
  
  defp handle_get_pubkey_request(request, original_event, state) do
    {_private_key, pubkey} = state.client_keypair
    
    response = %{
      "id" => request["id"],
      "result" => pubkey,
      "error" => nil
    }
    
    send_encrypted_response(response, original_event.pubkey, state)
    {:ok, state}
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
              # Try to parse as signed event JSON
              case Jason.decode(result) do
                {:ok, event_data} -> {:ok, Event.from_map(event_data)}
                _ -> {:ok, result}
              end
            result -> {:ok, result}
          end
        end
        
        GenServer.reply(from, result)
        new_state = %{state | pending_requests: Map.delete(state.pending_requests, request_id)}
        {:ok, new_state}
    end
  end
  
  defp send_encrypted_response(response, recipient_pubkey, state) do
    {private_key, _} = state.client_keypair
    
    # TODO: Implement NIP-44 encryption
    encrypted_content = encrypt_nip44(Jason.encode!(response), private_key, recipient_pubkey)
    
    event = Event.create(24133,
      content: encrypted_content,
      tags: [["p", recipient_pubkey]]
    )
    
    signed_event = Event.sign(event, private_key)
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
  
  defp generate_request_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
  
  # Placeholder functions for NIP-44 encryption/decryption
  # These will be implemented separately
  defp encrypt_nip44(plaintext, sender_privkey, recipient_pubkey) do
    # TODO: Implement NIP-44 encryption
    # For now, return base64 encoded plaintext as placeholder
    Logger.warning("NIP-44 encryption not yet implemented, using placeholder")
    Base.encode64("PLACEHOLDER_ENCRYPTED:" <> plaintext)
  end
  
  defp decrypt_nip44(ciphertext, recipient_privkey, sender_pubkey) do
    # TODO: Implement NIP-44 decryption  
    # For now, decode the placeholder
    Logger.warning("NIP-44 decryption not yet implemented, using placeholder")
    case Base.decode64(ciphertext) do
      {:ok, "PLACEHOLDER_ENCRYPTED:" <> plaintext} -> {:ok, plaintext}
      _ -> {:error, "decryption failed"}
    end
  end
end
