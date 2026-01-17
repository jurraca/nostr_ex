# NostrEx

## Overview

NostrEx is an OTP-compliant Nostr client library for Elixir applications. It provides a functional interface for connecting to Nostr relays, managing subscriptions, and sending/receiving Nostr events. The library follows Elixir/OTP conventions with GenServer-based relay management and uses the secp256k1 elliptic curve for cryptographic operations required by the Nostr protocol.

## User Preferences

Preferred communication style: Simple, everyday language.

## API Design Philosophy

The library follows a clean separation of concerns:

1. **Create** - Build data structures (events, subscriptions)
2. **Sign** - Optionally sign events with a private key
3. **Send** - Transmit to relays

### Quick Start

```elixir
# Connect to a relay
{:ok, "relay.damus.io"} = NostrEx.connect("wss://relay.damus.io")

# Create and send a subscription
{:ok, sub} = NostrEx.create_sub(authors: [pubkey], kinds: [1])
:ok = NostrEx.send_sub(sub)
:ok = NostrEx.listen(sub)

# Create, sign, and send an event
{:ok, event} = NostrEx.create_event(1, content: "Hello Nostr!")
{:ok, signed} = NostrEx.sign_event(event, private_key)
{:ok, event_id, []} = NostrEx.send_event(signed)
```

### Public API (NostrEx module)

**Relay Management:**
- `connect/1` - Connect to a relay URL
- `disconnect/1` - Disconnect from a relay
- `list_relays/0` - List connected relays
- `relay_states/0` - Get detailed relay status

**Events:**
- `create_event/2` - Create an unsigned event
- `sign_event/2` - Sign an event with a private key
- `send_event/2` - Send a signed event to relays

**Subscriptions:**
- `create_sub/1` - Create a subscription with filters
- `send_sub/2` - Send a subscription to relays
- `listen/1` - Register to receive events for a subscription
- `close_sub/1` - Close a subscription
- `list_subs/0` - List active subscriptions

## System Architecture

### Core Components

**Relay Management**
- `NostrEx.RelayManager` - Orchestrates connections to multiple Nostr relays
- `NostrEx.RelayAgent` - Agent-based state management for relay data
- `NostrEx.Socket` - WebSocket connection handling for relay communication
- Relays are tracked by name as strings (hostnames) via a `RelayRegistry`, abstracting away PID management

**Client Interface**
- `NostrEx` - Main public API module (user-facing)
- `NostrEx.Client` - Internal client implementation (not for direct use)
- `NostrEx.Subscription` - Subscription struct with id, filters, created_at

**Protocol Support**
- `NostrEx.Nip05` - Implementation of NIP-05 (DNS-based identity verification)
- Uses `nostr_lib` dependency for core Nostr protocol structures (events, filters, tags, messages)

**Utilities**
- `NostrEx.Utils` - Helper functions for common operations

### Design Patterns

- **OTP Supervision**: Application follows OTP patterns with `NostrEx.Application` as the entry point
- **Process Registry**: Relays are registered by string names (hostnames) for easy lookup without PID tracking
- **Functional API**: Public-facing functions return tuples like `{:ok, result}` or `{:error, reason}`
- **Tagged Results**: Operations across multiple relays return `{:ok, value, failures}` for partial success
- **Struct-based API**: Subscriptions use `%NostrEx.Subscription{}` for type safety
- **Silent by Default**: Library logs only via return values, not Logger calls

### Cryptography

Uses `lib_secp256k1` (Elixir NIF bindings for bitcoin-core's secp256k1 C library) for:
- Schnorr signatures (required by Nostr)
- Key derivation and management
- Event signing and verification

**Build Requirements**: The secp256k1 NIF requires native compilation tools:
- Linux: `autotools`
- macOS: `make`, `autoconf`, `autobuild`
- Nix: `autoreconfHook` (included in project devShell)

## External Dependencies

### Core Protocol
- **nostr_lib** - Low-level Nostr protocol structures (events, filters, messages, tags)
- **lib_secp256k1** - Cryptographic operations via bitcoin-core's secp256k1 (NIF-based)
- **ex_bech32** - Bech32 encoding/decoding for Nostr key formats

### Networking
- **mint** - Low-level HTTP client
- **mint_web_socket** - WebSocket support for Mint (HTTP/1 and HTTP/2)
- **finch** - HTTP client built on Mint with connection pooling
- **req** - High-level HTTP client for simpler requests
- **bandit** - HTTP server (Elixir-based, likely for testing)
- **plug** - Web application specification and utilities

### Data Handling
- **jason** - JSON encoding/decoding

### Development & Documentation
- **ex_doc** - Documentation generation
- **makeup/makeup_elixir/makeup_erlang** - Syntax highlighting for docs

### Supporting Libraries
- **telemetry** - Event dispatching for metrics/instrumentation
- **nimble_pool** - Resource pooling
- **nimble_options** - Options validation
- **nimble_parsec** - Parser combinators
- **castore** - CA certificate store
- **hpax** - HPACK header compression for HTTP/2
