# NostrEx

A lightweight, OTP-compliant Nostr client library for Elixir applications. This library provides a clean interface for connecting to Nostr relays, managing subscriptions, and handling Nostr events.

## Features

- OTP-compliant architecture with proper supervision
- Simple subscription management
- NIP-05 verification support
- Built on top of Mint WebSocket

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
{:ok, _pid} = NostrEx.connect_relay("wss://relay.example.com")
```

### Sending Notes

```elixir
# Send a simple note
NostrEx.send_note("Hello Nostr!", private_key)

# Send a long-form note
NostrEx.send_long_form("# My Blog Post\n\nContent here...", private_key)
```

### Subscriptions

NostrEx forwards messages received via a Nostr subscription to the process that created the subscription.

Put another way, the process you call a `NostrEx.subscribe_*` function from will then receive the events for that subscription.
It's up to you to decide how to handle those received events.

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
  kinds: [1],
  since: unix_timestamp
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
This dependency compiles the libsecp256k1 C library for cryptographic operations, therefore you will need a C compiler
to compile this project.

## Contributing

Issues and pull requests are welcome! Please ensure you add tests for any new functionality.

## License

MIT License - see LICENSE for details.
