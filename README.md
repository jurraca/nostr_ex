# NostrEx

An OTP-compliant Nostr client library for Elixir applications. It provides an interface for connecting to Nostr relays, managing subscriptions, sending and receiving Nostr events.

## Installation

Add `nostr_ex` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:nostr_ex, "~> 0.1.0"}
  ]
end
```

## Usage

### Connecting to Relays

```elixir
# Connect to a relay
{:ok, :relay_example_com} = NostrEx.connect_relay("wss://relay.example.com")
```

Relays are tracked by name as atoms via the `RelayRegistry`. All public facing functions expect this name as input, so you don't have to worry about PIDs. See `RelayManager.registered_names/0`.

### Sending Notes

```elixir
# Send a simple note
iex(1)> NostrEx.send_note("Hello Nostr!", private_key)

# Create an event with kind and attrs
iex(2)> NostrEx.create_event(1, %{content: "hello joe"})
%Nostr.Event{
  id: nil,
  pubkey: nil,
  kind: 1,
  tags: [],
  created_at: ~U[2025-08-03 15:29:15.261264Z],
  content: "hello joe",
  sig: nil
}

# Sign the event with your hex-encoded private key
iex(3)> {:ok, signed} = NostrEx.sign_event(event, private_key)
{:ok,
 %Nostr.Event{
   id: "871a08bf8e1b6d286d92238ce44648a94f7397042dd01a4ecc6db0afed745ec3",
   pubkey: "93155d8268a995888fe935ed9de633be690303ab37ba9d698c9f715076a99563",
   kind: 1,
   tags: [],
   created_at: ~U[2025-08-03 15:33:30.652067Z],
   content: "hello joe",
   sig: "60278f60548d5fa49841e0b7518201625aba9a9cf1cdc6d72621290b1943c21971d90c5ca3c2fba49b00ef84f488bac8bc0932c8ccc5ba5e3af2121ce7ad67c9"
 }}

 # send it, returns the event ID
 iex(4)> NostrEx.send_event(signed)
 {:ok, "871a08bf8e1b6d286d92238ce44648a94f7397042dd01a4ecc6db0afed745ec3"}
```

The `send`-type functions take a `send_via` option in `opts` to specify which relays to send the event to.
If not specified, all currently connected relays will be used.

### Subscriptions

NostrEx forwards messages received via a Nostr subscription to the process that created the subscription.
It's up to you to implement how to handle those received events.

You can subscribe to any subscription ID by calling
`Registry.register(NostrEx.PubSub, sub_id, nil)` from the process you want to be subscribed,
and similarly unsubscribe the current process with `Registry.unregister(NostrEx.PubSub, sub_id)`.

```elixir
# Subscribe to a user's notes
NostrEx.subscribe_notes(pubkey)

# Get a user's profile
NostrEx.subscribe_profile(pubkey)

# Get a user's following list
NostrEx.subscribe_follows(pubkey)

# Custom subscription with filters
NostrEx.send_subscription([
  authors: [pubkey],
  kinds: [30023],
  since: 1753135689
])
```

### NIP-05 Verification

```elixir
# Verify a NIP-05 identifier
NostrEx.Nip05.verify("user@example.com")
```

## Architecture

NostrEx uses a supervision tree with the following components:

- `RelayManager`: supervises WebSocket connections to relays
- `RelayAgent`: manages subscription state across relays
- `Socket`: handles individual WebSocket connections
- `PubSub`: use Registry to dispatch events to listeners
- `RelayRegistry`: Registry for mapping relay names to connection pids

This library is built on [Sgiath](https://github.com/Sgiath)'s [nostr_lib](https://github.com/Sgiath/nostr-lib) library.
This dependency compiles the libsecp256k1 C library for cryptographic operations, 
therefore you will need a C compiler to build this project.

## Contributing

Issues and pull requests are welcome! Please add tests for any new functionality.

## License

MIT License - see LICENSE for details.
