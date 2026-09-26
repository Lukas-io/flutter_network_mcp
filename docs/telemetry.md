# Telemetry

glint_network sends nothing anywhere unless you turn sharing on.

## What stays on your machine

Every tool call adds a row to the `tool_events` table of the local capture database: the time, the tool name, the outcome (ok, empty or error), the names of the arguments used (never their values), how long it took, the reply size, an estimated token count and, on failure, the error kind. `usage_stats` and `glint_network usage` read it back. Set `GLINT_NETWORK_NO_USAGE=true` to stop recording it.

## What is sent if you opt in

Set `GLINT_NETWORK_TELEMETRY=on` to share two kinds of anonymous report with `https://flutter-network-telemetry.wisdomiyamu.workers.dev/v1/telemetry`:

- **A daily usage summary**, sent at startup at most once a day: per tool, call counts, ok/empty/error counts and rates, p50 and p95 latency, average reply size, estimated tokens and error kinds; which tool followed which (names and outcomes only); how often an error was recovered on the next call; the time window and event-id range covered.
- **A crash report** when the server hits an uncaught error: the error class, the first 200 characters of the error message with paths, tokens, keys and passwords masked, the first 8 stack frames with home and project paths removed, and a signature for grouping.

Both also carry the package version and commit, whether it is a compiled build, the operating system and version, the Dart SDK version, and a random install id created once in the data directory (`install-id`), not derived from your username, paths or hardware.

Never sent: captured requests, responses, headers, bodies, URLs or logs; argument values; app, project or device names; file paths; the VM service or DTD address; environment variables.

## Checking what was sent

Every report is written to the hash-chained `telemetry-audit.log` in the data directory before any network attempt. `glint_network usage ship --dry-run` shows the next summary without sending it, `glint_network audit show` lists what was recorded, and `glint_network audit verify` checks that the log was not edited.

## Switches

| Variable | Effect |
| --- | --- |
| `GLINT_NETWORK_TELEMETRY=on` | Share the anonymous reports. Off unless set. |
| `DO_NOT_TRACK=1` | Never share, even with the opt-in. |
| `GLINT_NETWORK_NO_TELEMETRY=true` | Never share anything. |
| `GLINT_NETWORK_NO_USAGE=true` | Never share usage summaries and stop recording them locally. |

An agent cannot turn sharing on: the switches are environment variables only.
