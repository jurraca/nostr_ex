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
{:ok, "relay.example.com"}
```

Relays are tracked by names via the `RelayRegistry`. All public facing functions expect this name as input, so you don't have to worry about PIDs. See `RelayManager.registered_names/0`.

### Reconnecting

Sockets are self-healing. Each socket owns its lifecycle: it connects on spawn, and if the relay is unreachable or drops the connection later, it retries automatically with full-jitter exponential backoff (default 500ms to 30s, infinite attempts). A relay that is down stays registered and visible in `NostrEx.relay_states/0` while it keeps retrying.

```elixir
# Wait up to 5s for the first handshake; tuning options available
{:ok, "relay.damus.io"} = NostrEx.connect("wss://relay.damus.io",
  backoff_min: 1_000,
  backoff_max: 60_000
)
```

Subscriptions survive disconnects: REQ payloads are recorded before being sent and replayed automatically after every successful handshake — including subscriptions created *while* a relay was down (they apply once it returns). Only a genuine relay `CLOSED` message removes a subscription.

Connection lifecycle transitions can be observed from any process:

```elixir
NostrEx.listen(:relay_events)

receive do
  {:relay_up, name} -> IO.puts("#{name} is back")
  {:relay_down, name, reason} -> IO.puts("#{name} down: #{reason}")
  {:retry_scheduled, name, attempt, delay_ms} -> IO.puts("retrying #{name} in #{delay_ms}ms")
end
```

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
```elixir
receive do
  {:event, sub_id, %{kind: 1} = event} ->
    IO.puts(event.content)
  {:eose, sub_id, relay} ->
    IO.puts("No more events for sub " <> sub_id <> " from relay " <> relay)
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
{:ok, %NostrCore.Event{
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
 %NostrCore.Event{
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

### Publish Acknowledgements

Relays answer publishes with `OK` messages. To receive yours, listen on the
event's topic **before** sending (fast relays acknowledge within milliseconds):

```elixir
NostrEx.listen({:ok, signed.id})
{:ok, _event_id, _errors} = NostrEx.send_event(signed)

receive do
  {:publish_ack, ^signed.id, %{success: true, relay: relay}} ->
    IO.puts("accepted by #{relay}")

  {:publish_ack, ^signed.id, %{success: false, message: reason}} ->
    IO.puts("rejected: #{reason}")
end
```

Each targeted relay answers once. There is no global ack topic — match on
the event ids you care about, and unregister when done with
`Registry.unregister(NostrEx.PubSub, {:ok, event_id})`.

### NIP-05 Verification

```elixir
# Verify a NIP-05 identifier
NostrEx.Nip05.verify("user@example.com")
```

## Architecture

NostrEx uses a supervision tree with the following components:

- `RelayManager`: supervises relay slots; each child `Socket` drives its own connection, reconnecting with exponential backoff on failure
- `RelayAgent`: source of truth for subscription payloads across relays (survives socket death, enabling replay-on-reconnect)
- `Socket`: one self-connecting process per relay; replays subscriptions after each handshake
- `PubSub`: use Registry to dispatch events to listeners
- `RelayRegistry`: Registry for mapping relay names to socket pids

Event, tag, filter, and message primitives come from [NostrCore](https://github.com/jurraca/nostr_core) (events, filters, tags, messages, bech32/NIP-19, secp256k1 crypto).
This dependency compiles the libsecp256k1 C library for cryptographic operations,
therefore you will need a C compiler to build this project.

## Contributing

Issues and pull requests are welcome! Please add tests for any new functionality.

## License

MIT License - see LICENSE for details.
