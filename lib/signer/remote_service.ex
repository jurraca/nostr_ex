
defmodule NostrEx.Signer.RemoteService do
  @moduledoc """
  NIP-46 Remote Signing service implementation.
  
  This module acts as a remote signing service that other clients can connect to.
  It handles incoming signing requests and responds with signed events.
  """
  
  use GenServer
  require Logger
  
  alias Nostr.{Event, Message}
  alias NostrEx.{Client, RelayManager}
  
  defstruct [
    :private_key,
    :pubkey,
    :relays,
    :permissions,
    :authorized_clients
  ]
  
  @spec start_link(binary(), [String.t()], keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(private_key, relay_urls, opts \\ []) when is_binary(private_key) do
    config = %{
      private_key: private_key,
      relay_urls: relay_urls,
      permissions: opts[:permissions] || [],
      authorized_clients: opts[:authorized_clients] || []
    }
    GenServer.start_link(__MODULE__, config, opts)
  end
  
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
  def init(config) do
    signer_pubkey = Nostr.Keys.get_public_key(config.private_key)
    
    state = %__MODULE__{
      private_key: config.private_key,
      pubkey: signer_pubkey,
      relays: config.relay_urls,
      permissions: config.permissions,
      authorized_clients: MapSet.new(config.authorized_clients)
    }
    
    {:ok, state, {:continue, :connect_to_relays}}
  end
  
  @impl GenServer
  def handle_continue(:connect_to_relays, state) do
    # Connect to all specified relays
    Enum.each(state.relays, fn relay_url ->
      RelayManager.connect(relay_url)
    end)
    
    # Subscribe to incoming requests
    subscribe_to_requests(state)
    {:noreply, state}
  end
  
  @impl GenServer
  def handle_info({:event, _sub_id, event}, state) do
    case handle_request_event(event, state) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, reason} ->
        Logger.error("NIP-46 request handling error: #{reason}")
        {:noreply, state}
    end
  end
  
  def handle_info(_msg, state), do: {:noreply, state}
  
  ## Private Functions
  
  defp subscribe_to_requests(state) do
    # Subscribe to events tagged to this signer
    filter = [p: [state.pubkey], kinds: [24133]]
    Client.send_sub(filter)
  end
  
  defp handle_request_event(event, state) do
    case decrypt_and_parse_request(event, state) do
      {:ok, request} ->
        handle_nip46_request(request, event, state)
      {:error, reason} ->
        Logger.warning("Failed to decrypt NIP-46 request: #{reason}")
        {:ok, state}
    end
  end
  
  defp decrypt_and_parse_request(event, state) do
    # TODO: Implement NIP-44 decryption
    case decrypt_nip44(event.content, state.private_key, event.pubkey) do
      {:ok, decrypted} ->
        case Jason.decode(decrypted) do
          {:ok, request} -> {:ok, request}
          _ -> {:error, "invalid JSON in decrypted content"}
        end
      error -> error
    end
  end
  
  defp handle_nip46_request(request, original_event, state) do
    case request["method"] do
      "connect" ->
        handle_connect_request(request, original_event, state)
      
      "sign_event" ->
        handle_sign_event_request(request, original_event, state)
      
      "get_public_key" ->
        handle_get_pubkey_request(request, original_event, state)
      
      "ping" ->
        handle_ping_request(request, original_event, state)
      
      _ ->
        send_error_response(request["id"], "unsupported method", original_event.pubkey, state)
        {:ok, state}
    end
  end
  
  defp handle_connect_request(request, original_event, state) do
    # Validate connection request and potentially add to authorized clients
    client_pubkey = original_event.pubkey
    
    response = %{
      "id" => request["id"],
      "result" => "ack",
      "error" => nil
    }
    
    send_encrypted_response(response, client_pubkey, state)
    
    # Add client to authorized list
    new_state = %{state | authorized_clients: MapSet.put(state.authorized_clients, client_pubkey)}
    {:ok, new_state}
  end
  
  defp handle_sign_event_request(request, original_event, state) do
    client_pubkey = original_event.pubkey
    
    # Check if client is authorized
    if MapSet.member?(state.authorized_clients, client_pubkey) do
      [event_json] = request["params"]
      
      case Jason.decode(event_json) do
        {:ok, event_data} ->
          event = Event.from_map(event_data)
          
          case Event.sign(event, state.private_key) do
            signed_event ->
              response = %{
                "id" => request["id"],
                "result" => Jason.encode!(Event.to_map(signed_event)),
                "error" => nil
              }
              
              send_encrypted_response(response, client_pubkey, state)
              {:ok, state}
          end
        
        _ ->
          send_error_response(request["id"], "invalid event format", client_pubkey, state)
          {:ok, state}
      end
    else
      send_error_response(request["id"], "unauthorized", client_pubkey, state)
      {:ok, state}
    end
  end
  
  defp handle_get_pubkey_request(request, original_event, state) do
    client_pubkey = original_event.pubkey
    
    response = %{
      "id" => request["id"],
      "result" => state.pubkey,
      "error" => nil
    }
    
    send_encrypted_response(response, client_pubkey, state)
    {:ok, state}
  end
  
  defp handle_ping_request(request, original_event, state) do
    response = %{
      "id" => request["id"],
      "result" => "pong",
      "error" => nil
    }
    
    send_encrypted_response(response, original_event.pubkey, state)
    {:ok, state}
  end
  
  defp send_error_response(request_id, error_message, recipient_pubkey, state) do
    response = %{
      "id" => request_id,
      "result" => nil,
      "error" => error_message
    }
    
    send_encrypted_response(response, recipient_pubkey, state)
  end
  
  defp send_encrypted_response(response, recipient_pubkey, state) do
    # TODO: Implement NIP-44 encryption
    encrypted_content = encrypt_nip44(Jason.encode!(response), state.private_key, recipient_pubkey)
    
    event = Event.create(24133,
      content: encrypted_content,
      tags: [["p", recipient_pubkey]]
    )
    
    signed_event = Event.sign(event, state.private_key)
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
