# NostrEx

A Nostr client for Elixir applications. Connect to Nostr relays, manage subscriptions, send and receiving Nostr events.

## Installation

Add `nostr_ex` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:nostr_ex, "~> 0.2.2"}
  ]
end
```

**Required dependencies**:

`nostr_ex` depends on `secp256k1`, bitcoin-core's C implementation of the secp256k1 curve, via Sgiath's [Elixir NIF](https://github.com/Sgiath/secp256k1). To compile the dependency successfully:
- on Linux, you'll need `autotools` installed
- on MacOS, you may need `make`, `autoconf` and `autobuild`.
- using Nix, all you need is `autoreconfHook` in your environment. It is included in the project devShell, see `nix/shell.nix`.

## Usage

### Connecting to Relays

```elixir
# Connect to a relay
iex(1)> NostrEx.connect("wss://relay.example.com")
{:ok, "relay_example_com"}
```

Relays are tracked by names via the `RelayRegistry`. All public facing functions expect this name as input, so you don't have to worry about PIDs. See `RelayManager.registered_names/0`.

### Receiving Events

Pass event filters to `create_sub/1`:

```elixir
# Receive only new events
now = DateTime.utc_now() |> DateTime.to_unix()
NostrEx.create_sub(kinds: [1], since: now)
> {:ok, %NostrEx.Subscription{...}}

# Send the subscription
NostrEx.send_sub(sub)
> {:ok, "abc123f891..."}
```

NostrEx receives events at the process that created the subscription.
A simple event handler to print kind 1 notes might look like:
```
receive do
  {:event, sub_id, %{kind: 1} = event} ->
    IO.puts(event.content)
  {:eose, sub_id} ->
    IO.puts("No more events for sub " <> sub_id)
  _ ->
    IO.puts(:stderr, "Unexpected message received")
end
```
The Nostr events are received via PubSub, and it's up to you to implement how to handle those received events.

To subscribe to the given `sub_id` on a different process, call
`NostrEx.listen(sub_id)` from the process, a shorthand for
`Registry.register(NostrEx.PubSub, sub_id, nil)`.
Similarly, unsubscribe the current process with `Registry.unregister(NostrEx.PubSub, sub_id)`.

### Sending Notes

```elixir
# Create a private key, and send a simple note, returns the event ID
iex(2)> privkey = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
"6dba065ffb6f51b4023d7d24a0c91c125c42ceff344d744d00f3c76e6cb5e03e"

# Create an event with kind and attrs
iex(4)> NostrEx.create_event(1, content: "hello joe")
{:ok, %Nostr.Event{
  id: nil,
  pubkey: nil,
  kind: 1,
  tags: [],
  created_at: ~U[2025-08-03 15:29:15.261264Z],
  content: "hello joe",
  sig: nil
}}

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
# and an error list
 iex(4)> NostrEx.send_event(signed)
 {:ok, "871a08bf8e1b6d286d92238ce44648a94f7397042dd01a4ecc6db0afed745ec3", []}
```

The `send`-type functions take a `send_via` option in `opts` to specify which relays to send the event to.
If not specified, all currently connected relays will be used.

Additionally, since most send operations usually happen towards multiple relays, the response is a tuple of the form `{:ok, value, error_list}` to send back partial failures where at least one send succeeded but others may not have.

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
