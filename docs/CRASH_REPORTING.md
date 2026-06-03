# Crash reporting (design stub, NOT IMPLEMENTED)

> Status: design sketch only. There is no crash-reporting code in
> `flutter_network_mcp` as of 0.6.2. This file is referenced by the
> `TODO(crash-telemetry)` comment in `bin/flutter_network_mcp.dart` and
> records the intended design for when an implementation lands.

## Motivation

When the MCP crashes on a user's machine today, the only signal the
maintainer gets is whatever the user (or their agent) decides to file as a
GitHub issue. Most crashes evaporate silently. The bar for the user is
high: notice the stderr trace, reproduce it, copy-paste the stack into a
bug report.

A lightweight, opt-IN telemetry channel would close that loop: when the
MCP process catches an uncaught error, anonymized info goes to a
maintainer-controlled collector so a fix can ship without the user ever
having to file anything.

## Constraints

1. **Opt-IN, never opt-out.** Off by default. Enabled only by the user
   setting `FLUTTER_NETWORK_MCP_CRASH_REPORT=true`. No nag prompt — if
   the env var isn't set, the telemetry code never runs.
2. **No PII, no app data, no source paths.** The captured payload must
   contain only safe identifiers: package version, OS family + version,
   Dart version, error class name, top of stack with file paths
   redacted to package-relative form. Never: user names, hostnames,
   project paths, captured HTTP bodies, headers, URLs from the target
   app, env-var contents.
3. **Best-effort, non-blocking.** A failed POST to the collector must
   not crash the MCP further or block the shutdown path. Single retry
   with a short total deadline (~3s).
4. **Local audit trail.** When telemetry runs, the same payload is
   written to `<data-dir>/crashes.log` so the user can see what was
   sent and grep for it if curious.
5. **One endpoint, version-pinned.** Hardcoded for now; future
   enhancement could read from env (`FLUTTER_NETWORK_MCP_CRASH_ENDPOINT`)
   for self-hosted collectors.

## Sketch

```dart
// bin/flutter_network_mcp.dart
Future<void> main(List<String> args) async {
  if (io.Platform.environment['FLUTTER_NETWORK_MCP_CRASH_REPORT']
          ?.toLowerCase() != 'true') {
    return _runMain(args);
  }
  await runZonedGuarded(
    () => _runMain(args),
    (error, stack) async {
      await CrashTelemetry.report(
        version: _packageVersion,
        error: error,
        stack: stack,
      );
      io.exitCode = 70;
    },
  );
}
```

```dart
// lib/src/telemetry/crash_telemetry.dart  (new)
class CrashTelemetry {
  static Future<void> report({
    required String version,
    required Object error,
    required StackTrace stack,
  }) async {
    final payload = <String, Object?>{
      'version': version,
      'os': '${io.Platform.operatingSystem} ${io.Platform.operatingSystemVersion}',
      'dart': io.Platform.version,
      'errorClass': error.runtimeType.toString(),
      'errorMessage': _truncate(error.toString(), 200),
      'stackHead': _redactPaths(_topNFrames(stack.toString(), 8)),
      'reportedAt': DateTime.now().toUtc().toIso8601String(),
    };
    await _localAuditLog(payload);
    await _post(payload).timeout(const Duration(seconds: 3));
  }
}
```

## Payload schema (proposed)

```jsonc
{
  "version": "0.6.2",
  "os": "macos Version 14.6 (Build 23G93)",
  "dart": "3.12.0",
  "errorClass": "StateError",
  "errorMessage": "DTD is not connected.",
  "stackHead": [
    "DtdClient._requireConnected (package:flutter_network_mcp/src/vm/dtd_client.dart:36)",
    "DtdClient.getConnectedApps (package:flutter_network_mcp/src/vm/dtd_client.dart:23)",
    "AutoAttacher._runTick (package:flutter_network_mcp/src/auto_attach.dart:189)"
  ],
  "reportedAt": "2026-06-03T12:34:56.000Z"
}
```

Notice what's NOT in there: user paths (HOME, cwd, the target Flutter
project path), the target app's vmServiceUri or DTD URI (could leak
the security token), any captured HTTP data.

## Open questions

- **Endpoint.** A simple Cloudflare Worker or Fly.io collector POSTing
  to a SQLite/Turso table would be enough. TBD when implementation
  lands.
- **Rate limiting.** Probably per-machine: one report per process, max
  one report every 5 minutes from the same machine ID hash. The
  machine ID hash itself would be derived from a stable salt (the
  data-dir path) + a maintainer-controlled HMAC key, so the collector
  can de-dupe without learning anything identifying.
- **Privacy doc.** Once implemented, README needs a short explainer of
  exactly what gets sent and how to opt back out.

## Not in scope

- Sentry/Bugsnag SDK integration. Too heavy a dep for what's
  effectively a one-shot POST.
- Performance/usage analytics. Crash reporting only — no tool-call
  counts, no DB sizes, no timing telemetry.
- Encrypted-at-rest collector storage. Standard TLS in transit is
  sufficient for the threat model (anonymized payloads with no
  user-identifying content).
