---
tool: network_discover_dtd
description: List Dart Tooling Daemon (DTD) instances on this machine by reading the standard `package:dtd` discovery directory. Each candidate carries the FULL ws:// URI with security token, plus workspaceRoot / pid / dartVersion / isLive / matchesCwd.
when_to_use: When the server started without `--dtd-uri` (the typical zero-config case in 0.6.2+), when multiple DTDs are running and you need to pick the right one, or when the user hasn't pasted a URI and you'd otherwise have to ask.
---

## DO NOT USE THIS TOOL WHEN

- The MCP server has already auto-discovered a DTD at startup AND `network_status.dtd.connected:true`. The work is done — just call `network_attach`.
- You explicitly want NOT to auto-discover (paranoid configs, CI, shared machines). Start the server with `--no-auto-discover-dtd` and rely on explicit `--dtd-uri`.
- You're hunting for a VM service URI directly — that's `network_status.knownApps[].uri` after attach, not this tool.
- You need to discover DTDs on a remote machine — this is filesystem-only and local-only by design.

## Use this when

- "Why isn't anything attached?" — first call after `network_status` shows no DTD connected. Discovery is filesystem-only, fast, zero side effects.
- Multiple `flutter run` instances are running; the auto-pick chose the wrong one and you want to see the full list.
- A discovery file might be stale (Dart process died uncleanly); pass `includeStale:true` to see dead candidates and `isLive:false` flags.
- A user's project lives outside the cwd that the MCP was launched from; pass `cwdMatch:false` to see every DTD on the machine.

## How it works

Reads the per-platform `package:dtd` discovery directory:

| Platform | Path |
|---|---|
| macOS   | `$HOME/Library/Application Support/dart/dtd` |
| Linux   | `$XDG_CONFIG_HOME/dart/dtd` (fallback `$HOME/.config/dart/dtd`) |
| Windows | `%APPDATA%/dart/dtd` |

Each file inside is a JSON document containing the full WebSocket URI (token included), `pid`, `epoch`, `dartVersion`, `workspaceRoot`, and optionally `ideName`. The tool:

1. Lists every file in the directory (defensive 64-file cap).
2. Parses each as JSON; skips unrecognizable / partially-written files silently.
3. Probes each candidate's `pid` for liveness (POSIX `kill -0`, Windows `tasklist`).
4. Ranks best-first: live > matchesCwd > newer epoch.
5. Applies the caller's `cwdMatch` / `includeStale` filters.
6. Caps at `limit` candidates.

## Inputs

- `cwdMatch: bool` — default `true`. When true, only candidates whose `workspaceRoot` equals the server's current working directory are returned. Set false to see all DTDs on the machine.
- `includeStale: bool` — default `false`. When true, candidates whose pid no longer responds to the OS probe are included (useful for forensics).
- `limit: int` — default 5, hard cap 20.

## Output

```json
{
  "summary": "2 candidate(s) returned (of 4 found, 4 live). Recommended: ws://127.0.0.1:54450/-y7LwW-MjnA= (pid 77534, /Users/lukasio/StudioProjects/sanga_mobile).",
  "discoveryDir": "/Users/lukasio/Library/Application Support/dart/dtd",
  "cwd": "/Users/lukasio/StudioProjects/sanga_mobile",
  "totalFound": 4,
  "liveCount": 4,
  "visibleCount": 2,
  "recommended": "ws://127.0.0.1:54450/-y7LwW-MjnA=",
  "candidates": [
    {
      "wsUri": "ws://127.0.0.1:54450/-y7LwW-MjnA=",
      "pid": 77534,
      "epochMs": 1780462678169,
      "dartVersion": "3.12.0 (stable) ...",
      "workspaceRoot": "/Users/lukasio/StudioProjects/sanga_mobile",
      "ideName": "Android Studio",
      "isLive": true,
      "matchesCwd": true,
      "discoveryFilePath": "/Users/lukasio/Library/Application Support/dart/dtd/77534"
    }
  ],
  "warnings": ["..."],
  "nextSteps": [
    "network_attach dtdUri:\"<recommended>\" — attach to the recommended candidate"
  ]
}
```

## Warnings the tool can emit

- `"Could not resolve the package:dtd discovery directory for this platform (env var HOME / XDG_CONFIG_HOME / APPDATA missing)..."` — the platform-specific env var that anchors the path is unset.
- `"Discovery directory ... does not exist..."` — the directory hasn't been created yet (no DTD has ever run, or Dart SDK predates package:dtd discovery).
- `"N discovery file(s) found but every recorded pid is dead..."` — files exist but no live processes back them. Pass `includeStale:true` to inspect them.
- `"N live DTD(s) found but none match cwd (...)..."` — DTDs are running but for other projects.
- `"N matching candidates; only the top X shown..."` — raise `limit` (hard cap 20).

## Auto-discovery at startup

This tool is the on-demand surface. The server ALSO auto-discovers at startup when `--dtd-uri` is not configured: it runs the same discovery, picks the best live candidate (preferring cwd match), and uses it as the default. A one-line stderr note tells the user which DTD was picked and how to override (`--dtd-uri` or `--no-auto-discover-dtd`).

When startup auto-discovery picked the right DTD, you usually don't need to call this tool — `network_status` already shows `dtd.connected:true` and `knownApps` ready for `network_attach`.
