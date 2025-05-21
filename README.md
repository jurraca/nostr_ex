
# Nostrbase

A lightweight, OTP-compliant Nostr client library for Elixir applications. This library provides a clean interface for connecting to Nostr relays, managing subscriptions, and handling events in the Nostr protocol.

## Features

- Multi-relay support with automatic connection management
- OTP-compliant architecture with proper supervision
- Automatic reconnection handling
- Simple subscription management
- NIP-05 verification support
- Built on top of Mint WebSocket for reliable connections

## Installation

Add `nostrbase` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:nostrbase, "~> 0.1.0"}
  ]
end
```

## Usage

### Connecting to Relays

```elixir
# Connect to a relay
{:ok, _pid} = Nostrbase.add_relay("wss://relay.example.com")
```

### Sending Notes

```elixir
# Send a simple note
Nostrbase.send_note("Hello Nostr!", private_key)

# Send a long-form note
Nostrbase.send_long_form("# My Blog Post\n\nContent here...", private_key)
```

### Subscriptions

```elixir
# Subscribe to a user's notes
Nostrbase.subscribe_notes(pubkey)

# Get a user's profile
Nostrbase.subscribe_profile(pubkey)

# Get a user's following list
Nostrbase.subscribe_follows(pubkey)

# Custom subscription with filters
Nostrbase.send_subscription([
  authors: [pubkey],
  kinds: [1],
  since: unix_timestamp
])
```

### NIP-05 Verification

```elixir
# Verify a NIP-05 identifier
Nostrbase.Nip05.verify("user@example.com")
```

## Architecture

Nostrbase uses a supervision tree with the following components:

- `RelayManager`: supervises WebSocket connections to relays
- `RelayAgent`: manages subscription state across relays
- `Socket`: handles individual WebSocket connections
- `PubSub`: use Registry to dispatch events to listeners
- `RelayRegistry`: Registry for mapping relay names to connections

## Contributing

Issues and pull requests are welcome! Please ensure you add tests for any new functionality.

## License

MIT License - see LICENSE for details.
