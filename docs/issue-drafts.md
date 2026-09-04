# Issue response drafts (not posted)

All nine were filed from one debugging session on 2026-09-03. They land together on the `agent-flow` branch; each reply names the commit that closes it and what is deliberately left open.

## #85 — reads against a dead session return empty successfully

Fixed (f1c04b2). A 5 s heartbeat marks a session whose VM stops answering as dead within seconds; it leaves the slot, its DB row ends, and `network_status` lists it under `stale` with `movedTo` when the last DTD probe saw the same app at a new URI. Any read that names a dead `sessionId` now carries a warning: "session N is no longer reachable (app exited at HH:MM); this reply is its preserved history… The app is now at <uri> — network_attach vmServiceUri:… to follow it". An empty *live* result from a corpse can no longer happen because the corpse is not live.

## #86 — auto-attach lands ~10 s after launch

Partly fixed (61ae258). The watcher now polls DTD every second while nothing is attached (a launch or relaunch is exactly when that is true) and for the first minute after start, so the attach happens as soon as the VM answers rather than up to 5 s later. Auto-attached sessions keep `preAttachUptimeMs`, and the first non-incremental `logs_tail` says plainly that records from before the attach were never captured. What is not fixed, and cannot be: the VM service keeps no log history, so there is no backfill to pull from; the honest answer stays "hot restart to re-run startup inside the window", and the tool now says it instead of looking silent.

## #87 — network_list "no HTTP captured" while search finds 12

Fixed (4583c9f). `since:0` now means everything the session persisted and is served from the DB even on a live session, so it cannot contradict `network_search` or `session_list`. `session_open` on a live session switches reads to that session's history and says so; it no longer reports success while changing nothing.

## #88 — logs_tail truncates at ~110 chars

Partly fixed (4583c9f). `logs_tail` gains `messageTruncateBytes` (default 2048, cap 65536), and a reply with any cut record now carries a warning naming how many were cut, with `truncated: true` and `totalLength` on the record. The ~110-character cut you saw is not this server's limit (it cuts at 2048 and flagged it even before); please check whether the client rendered a longer message on one line, and if you can reproduce a 110-char cut with `truncated` absent, send the raw reply and I will chase it.

## #89 — auto-attach ignores the log buffer size

Fixed (61ae258). Default ring is 2000 (cap 20000). `auto_attach_config action:"set" logBufferSize:8000` persists a size every attach uses, auto or manual, and `network_attach logBufferSize` still overrides per call. When records rotate out between two reads, `logs_tail` says exactly how many (`droppedSinceLastRead`) instead of "may have rotated out".

## #90 — cap of 4 counts dead sessions; freeing a slot ends a session

Fixed (f1c04b2). Only live sessions count toward the cap, the default is 8, and hitting it runs the heartbeat first so a suspect session is evicted rather than counted. `network_detach keep:true` frees a slot without ending the DB session. The four sessions created within 2 ms for one app were a race between auto-attach, the migration watcher and a manual call; attaches now take an in-flight lock per target, a failed attach ends the row it created, and startup ends rows an earlier process left open.

## #91 — native SDK traffic invisible with no warning

Fixed in two steps (e12cb2d, b83ecb1). `network_status.captureBoundary`, every empty `network_search` / `network_summarize`, and the server instructions now say: only dart:io traffic is captured, native SDK traffic is not visible, absence is not evidence. And `network_attach nativeLogs:true` (or `auto_attach_config action:"set" nativeLogs:true`) streams the device's own log for the app into `logs_tail` as `source:"native"`, so PostHog / Mixpanel output is at least readable. Capturing native HTTP itself is not possible from the VM service.

## #92 — every response nags about thousands of alerts

Fixed (ad27070). `pendingAlerts` counts only the session in scope and is omitted when none is; a repeated crash signature is one alert; `flutter_error` is critical for the first crash of a session and an error after that; the alerts_drain line is gone from `nextSteps` unless the records you just read raised alerts. The retention sweep also caps pending alerts at 200 per session.

## #93 — a filtered logs_tail took more than 120 s

Bounded (4583c9f), root cause not reproduced. The live path is an in-memory scan and returns in milliseconds here, so the wait almost certainly came from the database: a second server process on the same `captures.db` (another IDE window) blocks writers, and before this change a read could sit on that lock indefinitely. The DB now opens with `busy_timeout = 5000` and reports `unresponsive_db` instead of hanging; every tool call runs under a 20 s deadline (`FLUTTER_NETWORK_MCP_TOOL_TIMEOUT_MS`) and comes back as `errorKind: timeout` with next steps instead of being backgrounded by the host; calls over 2 s are logged to stderr with their duration. If it recurs, the stderr line will name the tool and time.
