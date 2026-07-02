# Orphaned-process cleanup — diagnosis, fixes, and remaining hygiene

**Date:** 2026-07-02 · **Trigger:** Activity Monitor showing dozens of `dart`/`claude` processes eating multiple GB.

## TL;DR

Every `flutter_network_mcp` host restart or `/mcp` reconnect **leaked a full server process, forever**. Six orphans (PPID 1, up to 2 days old) were on the machine — including the 0.8.4 server orphaned by this very session's `/mcp` reconnect an hour earlier. Root cause: the server had **no shutdown path at all**; fixed in fnmcp **0.9.17** (this repo) and hardened in **glint**. Both verified. The huge processes you saw are a mix of three different stories — only one of them was ours.

## What was actually in that process list

| What you saw | Who owns it | Verdict |
|---|---|---|
| 6× `flutter_network_mcp` (sh + dartvm pairs and bare dartvm), PPID 1, up to 1d22h old | **This repo — the bug** | Orphans. One (PID 13329, age 2h28m) was our own session's pre-update 0.8.4 server, orphaned by the `/mcp` reconnect. |
| `frontend_server_aot.dart.snapshot` (921 MB), 2× `dartdev_aot` (708/404 MB — actually `dart language-server`) | **Android Studio** (parented to PID 45709, the Studio process) | Not a leak. Studio's Flutter compile daemon + two Dart analysis servers. They die with Studio. Big, but Studio's business. |
| 8× `dart:glint.dart` (~175–205 MB each) | **Live claude sessions** (each parented to a running `claude` PID) | Not orphans — yet. One glint per open session is by design; the count is high because ~10 claude sessions are open (cmux). Glint had a *conditional* version of the same bug (see below). |
| ~11× `claude` (300–750 MB each, some 8 days old) | **cmux-held terminals** | Not orphans — live interactive sessions you've stopped using. No code can fix this; see "cmux hygiene". |

## Root cause (fnmcp)

`bin/flutter_network_mcp.dart` started the server, the auto-attach poller, and the session migrator, then `_runMain` returned. Nothing ever listened for the end of the world:

- **No `server.done` handler.** `package:dart_mcp` completes `done` when the stdio channel closes (host died / reconnected → stdin EOF) — fnmcp ignored it, so the timers + sqlite handle + DTD sockets kept the VM alive indefinitely.
- **No signal handlers.** And the pub `sh` shim (`~/.pub-cache/bin/flutter_network_mcp`) neither `exec`s nor forwards signals, so a SIGTERM aimed at the wrapper kills only the shell; the grandchild dartvm survives re-parented to PID 1. This is why two orphans were bare dartvm processes with no wrapper.

So the lifecycle was: host dies → stdin EOFs → dart_mcp completes `done` → **nobody cares** → process lives until reboot.

## Fix 1 — flutter_network_mcp 0.9.17 (this repo)

`bin/flutter_network_mcp.dart`: new `_installLifecycleGuard(server)` — two triggers, one exit path:

1. `server.done` → "MCP host closed the stdio channel"
2. `SIGTERM` / `SIGINT` watchers (wrapped for Windows, where sigterm can't be watched)

Both run: stderr notice → best-effort `CapturesDatabase.close()` (WAL checkpoint + `PRAGMA optimize`) → `io.exit(0)`. `exit()` is deliberate: lingering timers and sockets do not get a vote.

**Verified:**
- Before: `dart bin/flutter_network_mcp.dart < /dev/null` still alive 8 s after instant stdin EOF (reproduces the orphan).
- After: exits 0 immediately, logging `flutter_network_mcp: MCP host closed the stdio channel — shutting down.`
- New regression tests in `test/lifecycle_guard_test.dart` spawn the real bin: stdin-close → exit 0 within 20 s; SIGTERM → exit 0. **Full suite: 322 tests green.**
- Version bumped 0.9.16 → 0.9.17 (`pubspec.yaml` + `lib/src/version.dart`), CHANGELOG entry added.

**Deployment note (important):** your installed binary is a git-pinned `pub global activate` snapshot. The fix reaches your real sessions only after you **push to master and run `flutter_network_mcp update`** (this was also the root cause of the "0.8.4 while master was 0.9.16" drift found in the agent-UX audit — same doc, F1).

## Fix 2 — glint (hardened)

Glint already did `await server.done` — sufficient when idle (verified: exits 0 on stdin EOF), but **conditionally broken when attached**: an open VM-service WebSocket keeps the event loop alive after `main` returns, and any `flutter run` child glint launched would be orphaned either way.

Changes (working tree of `~/StudioProjects/glint`, branch `tools-audit` — uncommitted, runs from source so the **next session restart picks it up**):

- `lib/src/mcp/session.dart`: new `killLaunchedApps()` — kills every `flutter run` process glint started (`_launchedApps`), so a dying glint never orphans its children.
- `bin/glint.dart`: same two-trigger guard — SIGTERM/SIGINT watchers + after `await server.done` → kill launched apps → `exit(0)`.

Verified: analyzer clean (the 2 pre-existing `unawaited_futures` infos are unrelated, confirmed via stash), idle stdin-EOF still exits 0, now with the shutdown notice.

## What you need to run (I was permission-blocked from killing system-wide PIDs)

Reap today's existing orphans (only processes whose parent is PID 1 — safe by construction, live sessions have live parents):

```sh
ps -eo pid,ppid,command | awk '$2==1 && (/flutter_network_mcp/ || /glint\.dart/) && !/awk/ {print $1}' | xargs kill
```

Then push + update so the fix reaches your sessions:

```sh
git push   # after committing 0.9.17
flutter_network_mcp update
# then reconnect flutter-network via /mcp in each session you care about
```

## cmux hygiene (the `claude` processes themselves)

The ~11 claude processes (some 8 days old, ~4–5 GB total, each also holding a glint + fnmcp + dart-mcp server) are **live sessions cmux keeps open** — no MCP-side fix can reap them, because from the OS's perspective they're healthy interactive processes. Options, in order of preference:

1. **Close unused cmux terminals** — everything parented to them (glint, fnmcp, dart mcp-server) now exits cleanly thanks to these fixes, so closing a session reclaims the whole tree.
2. List candidates by age when you want to prune: `ps -eo pid,etime,rss,command | grep -E '[c]laude$' | sort -t- -k1 -r`
3. If you want automation, a launchd/cron job that kills `claude` processes idle > N days is possible, but killing an interactive session can eat unsaved terminal state — I'd start with (1).

## Related: the 1.0.0 sprint

This bug is the *server-side sibling* of audit finding **F18/RC4** (server never notices the *app* dying). Same design lesson both directions: every long-lived connection needs a death handler. Worth folding into the RC4 work in the fixing sprint (`docs/agent-ux-audit-2026-07-02.md`).
