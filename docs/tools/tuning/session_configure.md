---
tool: session_configure
description: Set process-wide sticky default filters that logs_tail / network_list inherit when the arg is omitted, a default network_list token budget, and an optional body decryption scheme for app-encrypted HTTP bodies.
when_to_use: When you'll run several logs_tail / network_list reads with the same filter and don't want to repeat it, or when the app encrypts its request/response bodies and you have the key.
---

## DO NOT USE THIS TOOL WHEN

- You only need a filter for a single read — just pass it to `logs_tail` / `network_list` directly.
- You want a permanent, persisted config — these defaults are in-memory and reset on server restart.
- You want to filter what gets CAPTURED — this only filters what reads RETURN. Use `ignored_hosts` / `alerts_config` for capture-time tuning.
- The bodies are only compressed or encoded (gzip, base64 JSON). Read tools already decode those; `bodyDecryption` is for app-level AES-CTR encryption only.
- You do not have the app's key and scheme from the user or the app's code. Guessing produces `decryptionFailed` on every body.

## Use this when

- You're investigating one app concern and every read wants the same lens: "only `[EventTracker]` logs at level ≥ 1000" or "only 4xx/5xx HTTP". Set it once here, then read without repeating the args.
- You keep re-typing the same `messageContains` / `statusMin` on consecutive calls.
- `network_list` replies are too large for the context and you want a standing token budget.
- Captured bodies are opaque hex/base64 blobs because the app encrypts them, and the user gave you the key. Set `bodyDecryption` and read or search the plaintext.

## How it works

Holds a single in-memory set of default filters. `logs_tail` and `network_list` read them to fill any filter argument you omit. An argument you DO pass on a read always wins for that call (even passing it as `null` to mean "no filter this time"). Resets on process restart.

`clear:true` runs first, so `clear:true levelMin:1000` resets everything and then sets `levelMin`. It also turns body decryption off.

`maxResponseTokens` becomes the default for `network_list`'s `maxTokens`: the `requests` array is trimmed newest-first to fit (about 4 characters per token, at least one row kept) and the reply reports `budget.dropped`. `logs_tail` does not apply it.

### Body decryption

`bodyDecryption:{...}` sets an AES-CTR scheme for this server process:

- The key lives only in this process's memory. It is never written to the capture DB and never echoed back; replies show `keyFingerprint` (the first 12 hex characters of the key's SHA-256). Usage telemetry records argument names only.
- The payload is split into IV and ciphertext by `ivMode`: `prefix` (IV first), `suffix` (IV last), or `infused` (the IV is spliced in at `ivOffset` and the ciphertext is the parts before and after it). For `encoding:"hex"`, `ivOffset` and `ivLength` count hex characters of the body text; for `base64` and `raw` they count decoded bytes. A body that is a JSON string (`"..."`) is unwrapped first for hex and base64.
- `network_get`, `network_body`, `network_body_outline` and `network_body_query` return the plaintext with `decrypted:true`. A body that does not fit the scheme comes back as captured, with `decrypted:false` and `decryptionFailed` giving the reason: not a hex string, not base64, no longer than the IV, `ivOffset + ivLength` past the end, or "the result is not UTF-8 text, so the key or scheme does not match this body". It never errors. `network_diff` and `network_drift` compare the decrypted bodies too, but do not add these flags.
- `network_search` and `network_correlate` search an in-memory plaintext index instead of the capture DB's index. It is built per session from the stored (still encrypted) bodies on the first search or correlate, and extended on later ones. Nothing decrypted is written to disk. The index is dropped whenever the scheme changes, decryption is turned off, or on `clear:true`, and it dies with the process.
- `network_replay`, `network_replay_as_test` and `session_export` keep the original captured bytes, since the server expects ciphertext.
- `bodyDecryption:{off:true}` or `clear:true` turns it off. Passing a new `bodyDecryption` object replaces the old scheme.

## Args

All optional. Pass a field to set it, pass it as `null` to unset just that field, `clear:true` to reset all, or no args to view the current defaults.

- `levelMin` (int) — default `logs_tail` levelMin.
- `loggerContains` (string) — default `logs_tail` loggerContains.
- `messageContains` (string | list) — default `logs_tail` messageContains (OR-matched).
- `source` (string) — default `logs_tail` source.
- `method` (string | list) — default `network_list` method(s).
- `hostContains` (string) — default `network_list` hostContains.
- `statusMin` / `statusMax` (int) — default `network_list` status bounds.
- `maxResponseTokens` (int): default token budget for `network_list` (its `maxTokens` arg overrides it). A non-positive value means no budget.
- `clear` (bool): reset ALL sticky defaults, and turn body decryption off.
- `bodyDecryption` (object): the decryption scheme. Fields:
  - `algorithm` (string): `aes-256-ctr` (default, 32-byte key) or `aes-128-ctr` (16-byte key).
  - `key` (string, required unless `off`): the app's key.
  - `keyEncoding` (string): how `key` is written: `utf8` (default), `hex` or `base64`. The decoded key must have the exact length the algorithm needs.
  - `encoding` (string): how the body holds the payload: `hex` (default), `base64` or `raw` bytes.
  - `ivMode` (string): `prefix` (default), `suffix` or `infused`.
  - `ivOffset` (int, default 0): `infused` only, where the IV starts. Hex: in hex characters, and it must be even. Base64/raw: in bytes.
  - `ivLength` (int): the 16-byte IV in the same unit, so 32 for hex and 16 for base64/raw (the defaults). Any other value is rejected.
  - `off` (bool): `true` turns decryption off and drops the plaintext index.

An invalid `bodyDecryption` (unsupported algorithm, missing key, wrong key length, unknown `encoding` / `ivMode` / `keyEncoding`, wrong `ivLength`, negative or odd hex `ivOffset`) returns `errorKind: bad_argument` with the reason and an example call. Filter fields set in the same call before the error keep their new values.

## Returns

```json
{
  "summary": "Sticky defaults active (levelMin, messageContains). ...",
  "defaults": {"levelMin": 1000, "messageContains": ["[EventTracker]"]},
  "bodyDecryption": {"active": false},
  "nextSteps": ["logs_tail now returns the filtered view without repeating args", "session_configure clear:true to drop all sticky defaults"]
}
```

With decryption on:
```json
{
  "summary": "No sticky default filters set. ... Body decryption is on (aes-256-ctr, key 3f9a1c0b7d2e); network_search reads the plaintext through an index kept in memory, never written to disk.",
  "defaults": {},
  "bodyDecryption": {
    "active": true,
    "algorithm": "aes-256-ctr",
    "encoding": "hex",
    "ivMode": "infused",
    "ivOffset": 10,
    "ivLength": 32,
    "keyFingerprint": "3f9a1c0b7d2e"
  },
  "warnings": ["decrypted bodies are returned as plaintext, so they land in this transcript; turn it off with bodyDecryption:{off:true} when done"],
  "nextSteps": ["..."]
}
```

`ivOffset` appears only for `ivMode:"infused"`.

## Example

```
> session_configure levelMin:1000 messageContains:["[EventTracker]"]
> logs_tail            # inherits levelMin + messageContains
> logs_tail levelMin:0 # this call overrides levelMin; messageContains still inherited
> session_configure clear:true
```

Encrypted API bodies (`cipher = payload[0:10] + payload[42:]`, `iv = payload[10:42]`, hex):
```
> session_configure bodyDecryption:{key:"<32-char key>", encoding:"hex", ivMode:"infused", ivOffset:10, ivLength:32}
< {bodyDecryption:{active:true, keyFingerprint:"3f9a1c0b7d2e", ...}, warnings:[...]}
> network_body id:"42" which:"response"
< {..., decrypted:true}
> network_search query:"rebate"
> session_configure bodyDecryption:{off:true}
```
