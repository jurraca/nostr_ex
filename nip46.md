Nostr Remote Signing

Overview:
    client generates client-keypair. This keypair doesn't need to be communicated to user since it's largely disposable. client might choose to store it locally and they should delete it on logout;
    A connection is established (see below), remote-signer learns client-pubkey, client learns remote-signer-pubkey.
    client uses client-keypair to send requests to remote-signer by p-tagging and encrypting to remote-signer-pubkey;
    remote-signer responds to client by p-tagging and encrypting to the client-pubkey.
    client requests get_public_key to learn user-pubkey.

Initiating a connection:
remote-signer provides connection token in the form:

bunker://<remote-signer-pubkey>?relay=<wss://relay-to-connect-on>&relay=<wss://another-relay-to-connect-on>&secret=<optional-secret-value>

user passes this token to client, which then sends connect request to remote-signer via the specified relays. Optional secret can be used for single successfully established connection only, remote-signer SHOULD ignore new attempts to establish connection with old secret.
Direct connection initiated by the client

client provides a connection token using nostrconnect:// as the protocol, and client-pubkey as the origin. Additional information should be passed as query parameters:

    relay (required) - one or more relay urls on which the client is listening for responses from the remote-signer.
    secret (required) - a short random string that the remote-signer should return as the result field of its response.
    perms (optional) - a comma-separated list of permissions the client is requesting be approved by the remote-signer
    name (optional) - the name of the client application
    url (optional) - the canonical url of the client application
    image (optional) - a small image representing the client application

Here's an example:

nostrconnect://83f3b2ae6aa368e8275397b9c26cf550101d63ebaab900d19dd4a4429f5ad8f5?relay=wss%3A%2F%2Frelay1.example.com&perms=nip44_encrypt%2Cnip44_decrypt%2Csign_event%3A13%2Csign_event%3A14%2Csign_event%3A1059&name=My+Client&secret=0s8j2djs&relay=wss%3A%2F%2Frelay2.example2.com

user passes this token to remote-signer, which then sends connect response event to the client-pubkey via the specified relays. Client discovers remote-signer-pubkey from connect response author. secret value MUST be provided to avoid connection spoofing, client MUST validate the secret returned by connect response.

Request Events kind: 24133

{
    "kind": 24133,
    "pubkey": <local_keypair_pubkey>,
    "content": <nip44(<request>)>,
    "tags": [["p", <remote-signer-pubkey>]],
}

The content field is a JSON-RPC-like message that is NIP-44 encrypted and has the following structure:

{
    "id": <random_string>,
    "method": <method_name>,
    "params": [array_of_strings]
}

    id is a random string that is a request ID. This same ID will be sent back in the response payload.
    method is the name of the method/command (detailed below).
    params is a positional array of string parameters.

Methods/Commands

Each of the following are methods that the client sends to the remote-signer.
Command 	Params 	Result
connect 	[<remote-signer-pubkey>, <optional_secret>, <optional_requested_permissions>] 	"ack" OR <required-secret-value>
sign_event 	[<{kind, content, tags, created_at}>] 	json_stringified(<signed_event>)
ping 	[] 	"pong"
get_public_key 	[] 	<user-pubkey>
nip04_encrypt 	[<third_party_pubkey>, <plaintext_to_encrypt>] 	<nip04_ciphertext>
nip04_decrypt 	[<third_party_pubkey>, <nip04_ciphertext_to_decrypt>] 	<plaintext>
nip44_encrypt 	[<third_party_pubkey>, <plaintext_to_encrypt>] 	<nip44_ciphertext>
nip44_decrypt 	[<third_party_pubkey>, <nip44_ciphertext_to_decrypt>] 	<plaintext>
