# Crash + bug telemetry (design + status)

> Status: **shipped in 0.7.1** (audit-log + payload + opt-out wired
> up; collector POST stubbed pending Cloudflare deploy — see
> "Collector status" below). The `TODO(crash-telemetry)` marker
> from 0.6.2 has been resolved; the runZonedGuarded handler in
> `bin/flutter_network_mcp.dart` now calls
> `TelemetryReporter.maybeReport`. This file is kept as the
> design spec + status tracker; see CHANGELOG `[0.7.1]` for the
> shipped-feature summary.

## Collector status (as of 0.7.1)

The trust-pact's LOCAL half (audit log + `audit verify` / `show` +
opt-out env var) is fully shipped. The REMOTE half (POST to
maintainer-controlled collector) is stubbed — `kCollectorEndpoint`
in `lib/src/telemetry/telemetry_constants.dart` is empty.

This split was deliberate: it lets us ship the user-facing
transparency surface today without waiting on infrastructure
deploy. When the Cloudflare URL is ready, a small follow-up patch
(0.7.1.x) flips the constant. Same payload, same audit log, same
opt-out — only the network path changes.

Deploy steps for the maintainer: see `docs/MAINTAINER_SETUP.md`
path A. The Worker + D1 schema in that doc match the wire payload
documented below.

## The trust pact

Telemetry is **on by default**, with an opt-out env var. In exchange, the MCP writes a **tamper-evident local audit log** of every byte it sends to the collector — same payload, same encoding, hash-chained so any silent edit is detectable. The user can run `flutter_network_mcp audit verify` at any time to walk the chain and prove nothing was sent without their knowledge.

This is the trade-off: more signal (so bugs surface in days instead of months when somebody bothers to file an issue), in exchange for **full transparency to the user about what we know**.

## Motivation

Most MCP crashes evaporate silently. The user sees a Dart trace, shrugs, moves on. The maintainer never finds out until somebody happens to file a GitHub issue weeks later — usually for the third or fourth person hitting the same bug, after the first three gave up.

Default-on telemetry closes that gap. The Phase 9 runZonedGuarded around `main()` already catches uncaught errors; with telemetry wired in, those crashes become signal we can act on within a day.

## Constraints

1. **Default ON.** Telemetry runs unless the user sets `FLUTTER_NETWORK_MCP_NO_TELEMETRY=true`. No opt-in dance, no nag prompt.
2. **Tamper-evident local audit log.** Every payload that goes to the wire ALSO goes to `<data-dir>/telemetry-audit.log` as a hash-chained append-only record. The user can audit + verify the chain at any time. As of 0.8.6 this log is shared: usage-analytics rollups (issue #79 Phase 3) append to the same chain, tagged `"kind":"usage_rollup"`, so `audit show` / `audit verify` cover both crash reports and usage rollups in one place.
3. **No PII, no app data, no source paths.** The payload contains only safe identifiers: package version, commit SHA, OS family + version, Dart version, error class, top of stack with file paths redacted to package-relative form. Never: user names, hostnames, project paths, captured HTTP bodies, headers, URLs from the target app, env-var contents, the contents of any captured DB row.
4. **Best-effort, non-blocking.** Network failure must not crash the MCP or block shutdown. Single attempt with a 3s total deadline. The audit log write happens BEFORE the network attempt, so even if the wire send fails the user still sees what we tried to send.
5. **Rate limit at the collector.** Max 5 reports per machine_hash per hour. A crash loop can't DOS the collector or fill the user's audit log unboundedly.
6. **One endpoint, version-pinned.** Hardcoded for now; future enhancement could read from env (`FLUTTER_NETWORK_MCP_TELEMETRY_ENDPOINT`) for self-hosted forks.

## The opt-out

```bash
export FLUTTER_NETWORK_MCP_NO_TELEMETRY=true
```

Set this and the telemetry code never runs. No network attempt, no audit log write, no nothing. The runZonedGuarded handler still catches uncaught errors and logs them to stderr — just doesn't report.

For regulated environments (SOC 2, healthcare, defense, customer machines with strict outbound policy) this is the path. Set the env var in your shell rc, your CI runner config, your container baseline.

## Local audit log

### Location

`<data-dir>/telemetry-audit.log` — same data dir as `captures.db`. On macOS: `~/Library/Application Support/flutter_network_mcp/telemetry-audit.log`.

### Format (one JSON-ish line per report)

```
<ts>|<prev_hash>|<payload_b64>|<this_hash>
```

Fields:

- `ts` — ISO-8601 UTC timestamp when the report was written.
- `prev_hash` — SHA-256 hex of the previous line's `this_hash`. First line uses 64 zeros.
- `payload_b64` — base64 of the EXACT JSON bytes that were sent (or would have been, if the wire send fails). Byte-for-byte parity with the POST body.
- `this_hash` — SHA-256 hex of `<ts>|<prev_hash>|<payload_b64>`. Forms the chain.

Why this format: a single line per entry means `tail -f` works for live monitoring. Base64 keeps the payload one-line. SHA-256 is fast enough that the hash overhead is invisible compared to a network attempt.

### Tamper-evidence (not tamper-prevention)

The audit log lives on the user's disk; they own it; they CAN edit it. The chain doesn't prevent that — it makes it visible. Any line edited in place breaks the local hash check. Any line removed breaks the next line's `prev_hash`. The user can prove to themselves (or to a third party) that the log is intact OR find the exact point where it diverges.

This is the same model as `git log` — the chain isn't enforced by the filesystem, it's enforced by the hashes that anyone with the file can verify.

### Verification command

```
flutter_network_mcp audit verify
```

Walks the file line by line:

1. Recomputes `this_hash` from `(ts, prev_hash, payload_b64)` and compares.
2. Checks each line's `prev_hash` against the previous line's `this_hash`.

Output on a clean chain:

```
flutter_network_mcp audit verify: 47 entries, chain intact.
First entry: 2026-06-04T10:30:00Z
Last entry:  2026-08-12T14:22:51Z
Use `flutter_network_mcp audit show` to view payloads.
```

Output on a break:

```
flutter_network_mcp audit verify: chain broken at entry 23 (2026-07-15T09:14:02Z):
  expected prev_hash = a3f7c8…
  actual   prev_hash = d2b15e…
The entries before 23 are intact. After 23, the chain cannot be verified.
```

### Inspection commands

```
flutter_network_mcp audit show              # decode + pretty-print every payload
flutter_network_mcp audit show --since 7d   # last 7 days
flutter_network_mcp audit show --signature <sig>  # only matching signature
```

## Wire payload (proposed)

```jsonc
{
  "version": "0.6.3",
  "commit": "4aa550c…",                          // 12 hex chars, from packageVersion + currentCommitSha
  "isAot": true,
  "os": "macos 14.6",                            // operatingSystem + operatingSystemVersion (truncated)
  "dart": "3.12.0",                              // Platform.version, version-only
  "errorClass": "StateError",                    // error.runtimeType.toString()
  "errorMessage": "DTD is not connected.",       // truncated 200 chars
  "stackHead": [                                 // top 8 frames, paths redacted
    "DtdClient._requireConnected (package:flutter_network_mcp/src/vm/dtd_client.dart:36)",
    "DtdClient.getConnectedApps (package:flutter_network_mcp/src/vm/dtd_client.dart:23)",
    "AutoAttacher._runTick (package:flutter_network_mcp/src/auto_attach.dart:189)"
  ],
  "signature": "a3f7c8d219b4",                   // sha256(errorClass + top-3-frames)[:12], dedupe key
  "machineHash": "f1a823bc91…",                  // hmac_sha256(dataDirPath, baked-in-salt)[:24], dedupe key
  "reportedAt": "2026-06-03T12:34:56Z"
}
```

What's NOT in the payload (enforced by the redactor, audited by the local log):

- `$HOME`, `cwd`, the target Flutter project path, any path under `/Users/<name>/…` or `C:\Users\<name>\…`
- The target app's vmServiceUri / DTD URI / connection token
- Any captured HTTP body, header, URL fragment
- Env var contents (only `FLUTTER_NETWORK_MCP_NO_TELEMETRY` presence is read, never logged)
- The contents of any `captures.db` row

## Path redaction (the hardest part)

Stack traces contain `package:` paths (safe, package-relative) AND raw filesystem paths (NOT safe, contain `$HOME`). The redactor walks each frame and replaces:

- `/Users/<name>/StudioProjects/<project>/…` → `<project>/…`
- `/Users/<name>/…` → `<home>/…`
- `C:\Users\<name>\<project>\…` → `<project>\…` (Windows equivalent)

Regex-based, runs as part of building `stackHead`. Unit-test with a fuzz corpus of real Dart traces — get this wrong and we leak filesystem layout.

## Signature (the magic field)

`signature = sha256(errorClass + top-3-frames-redacted)[:12]`

Identical bugs collapse into one row group at the collector. `SELECT signature, COUNT(*), MAX(received_at) FROM crashes GROUP BY signature ORDER BY 2 DESC` answers "what's the most common crash right now."

Stable across machines: the only inputs are class name + redacted package-relative paths + line numbers. Different patch versions can change line numbers; we accept that as the "what changed" signal.

## Collector

Cloudflare Worker + D1 SQLite. ~50 lines of Worker code, free tier handles 100K writes/day. Schema:

```sql
CREATE TABLE crashes (
  id INTEGER PRIMARY KEY,
  received_at INTEGER NOT NULL,
  reported_at INTEGER NOT NULL,
  version TEXT NOT NULL,
  commit_sha TEXT,
  os TEXT NOT NULL,
  dart_version TEXT,
  is_aot INTEGER NOT NULL,
  error_class TEXT NOT NULL,
  error_message TEXT,
  stack_head TEXT NOT NULL,   -- JSON array
  signature TEXT NOT NULL,
  machine_hash TEXT NOT NULL
);
CREATE INDEX idx_signature ON crashes(signature, received_at);
CREATE INDEX idx_version ON crashes(version, received_at);
```

Worker endpoint: `POST /v1/crashes`. Verifies the payload schema, rate-limits per `machine_hash` (max 5/hour, return 429 on excess, drop silently on the client), inserts a row, returns 204.

Future enhancement: `gh issue create` from a Worker cron when a new signature crosses a count threshold. Probably overkill until you see real volume.

## Implementation sketch

```dart
// bin/flutter_network_mcp.dart — Phase 9's runZonedGuarded handler gains:
await runZonedGuarded(() => _runMain(args), (error, stack) {
  io.stderr.writeln('flutter_network_mcp: UNCAUGHT ERROR …');
  unawaited(TelemetryReporter.maybeReport(
    error: error,
    stack: stack,
    dataDir: _resolvedDataDir,
  ));
  io.exitCode = 70;
});
```

```dart
// lib/src/telemetry/telemetry_reporter.dart (new)
class TelemetryReporter {
  static const String _endpoint = 'https://...';      // baked
  static const String _publicSalt = '...';            // baked

  static Future<void> maybeReport({
    required Object error,
    required StackTrace stack,
    required String dataDir,
  }) async {
    final env = io.Platform.environment;
    if (env['FLUTTER_NETWORK_MCP_NO_TELEMETRY']?.toLowerCase() == 'true') {
      return;
    }
    final payload = _buildPayload(error, stack, dataDir);
    _appendAudit(dataDir, payload);        // always — even if network fails
    await _post(payload).timeout(const Duration(seconds: 3)).catchError((_) {});
  }
}
```

```dart
// lib/src/telemetry/audit_log.dart (new)
//   - Reads the last line, extracts prev hash
//   - Appends new line with computed this_hash
//   - chmod 0644 so the file is user-readable for inspection
//   - Defends against partial writes via tempfile + rename (POSIX) or
//     transaction-style write on Windows
```

```dart
// New `audit` subcommand in bin/, dispatched alongside install + update.
// Subcommands: verify, show, show --since, show --signature
```

## Phasing

1. **Worker + D1.** Deploy to Cloudflare free tier. Endpoint URL becomes a constant. ~2 hours.
2. **Dart-side reporter + audit log + signature builder + path redactor.** Unit-test the redactor against a fuzz corpus. ~4 hours.
3. **`audit` subcommand** — verify, show, show with filters. ~2 hours.
4. **README transparency section** documenting exactly what gets sent, how to verify, how to opt out. ~1 hour.

Total: ~1 day's work. Ship in a minor version bump (0.7.0), call it out in the CHANGELOG as a default-on behavior change so users see the diff.

## What this doesn't do

- **Performance / usage analytics.** Tool-call counts, DB sizes, timing — none of it. Crash telemetry only.
- **Sentry / Bugsnag SDKs.** Too heavy a dep for what's effectively a one-shot POST.
- **Encrypted-at-rest collector storage.** Standard TLS in transit is sufficient — anonymized payloads with no user-identifying content don't need at-rest encryption beyond what D1 provides.
- **Cross-machine deduplication of users.** `machine_hash` is per-data-dir, not per-user. Two installs on the same machine with different `--data-dir` values count as two machines. That's fine.

## Pre-launch checklist (for whoever picks this up)

- [ ] Redactor unit tests pass against a corpus of real-world Dart traces (gather from existing GitHub issues).
- [ ] Local audit log is byte-for-byte identical to the wire payload — fuzz-test with random reports + diff.
- [ ] `audit verify` correctly identifies hand-edited entries in a synthetic broken log.
- [ ] Rate limit at the collector returns 429 cleanly; client drops silently without retry.
- [ ] README documents the on-by-default behavior + opt-out + audit log in plain language.
- [ ] CHANGELOG entry calls out the default change loudly (e.g. `## [0.7.0] — Default-on crash telemetry with local audit trail`).
- [ ] CRASH_REPORTING.md (this file) updated to reflect the actual implementation if it diverges from this design.
