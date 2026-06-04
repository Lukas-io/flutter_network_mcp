---
tool: report_issue
description: File a GitHub issue against this MCP from inside an agent turn. Two types — "bug" (code issue, wrong output, crash) and "ux" (works but feels awkward / confusing / slow / unclear). Path-redacted before submission.
when_to_use: When something breaks or feels off and the agent has enough context to describe it. Don't wait for the user to ask — file proactively. See the `instructions` directive in the MCP server.
---

## DO NOT USE THIS TOOL WHEN

- You don't have a clear summary or body to file — vague reports waste maintainer cycles.
- The issue is about the user's app (their HTTP error, their RenderFlex overflow) — that's their bug, not the MCP's.
- You've already filed an issue for the same problem this session — the maintainer dedupes upstream but local duplicates are noise.
- You're not sure whether something is a bug or just unfamiliar — peek at the existing issues first via `gh issue list --repo Lukas-io/flutter_network_mcp` (if you have shell access).

## Use this when

- A tool returns an unexpected `error` field, malformed shape, or panics.
- A tool description mismatches actual behavior.
- A response field is documented but missing (or undocumented but present).
- The agent UX feels worse than necessary — too many calls to do a simple thing, ambiguous nextSteps, confusing error messages.
- The MCP server crashed and `audit verify` / `audit show` show a relevant entry.

## How it works

1. Path redactor (same one used by telemetry stack frames) runs over `title` + `body`. Strips `/Users/<name>/StudioProjects/<x>/...` to `<project:X>/...`, `/Users/<name>/...` to `<home>/...`, plus Windows equivalents. Defense-in-depth — agents should still avoid putting filesystem paths in issue text.
2. Labels picked by `type`: `bug` → `[bug, agent-filed]`; `ux` → `[ux-friction, agent-filed]`. The `agent-filed` label lets the maintainer triage agent-vs-human reports.
3. If `gh` CLI is installed AND `auto:true` (default): the tool shells `gh issue create --repo Lukas-io/flutter_network_mcp --title ... --body ... --label ...` and returns the URL of the filed issue.
4. Else: returns a paste-ready GitHub deep link with `title=`, `body=`, `labels=` query parameters. The user opens the URL in a browser and the new-issue form arrives pre-filled.

## Args

- `type` (string, required) — `"bug"` or `"ux"`.
- `title` (string, required) — one-line summary.
- `body` (string, required) — GitHub-flavored markdown. Include context: what broke, what you expected, the failing tool call + args.
- `auto` (bool, default true) — try `gh issue create` first. Set false to skip straight to the paste-ready URL.

## Returns

**Successful gh-cli filing:**
```jsonc
{
  "filed": true,
  "method": "gh-cli",
  "type": "bug",
  "labels": ["bug", "agent-filed"],
  "title": "network_get returns null mimeType for application/json bodies",
  "url": "https://github.com/Lukas-io/flutter_network_mcp/issues/42",
  "nextSteps": [
    "Mention the URL to the user: https://github.com/...",
    "Optionally save a session_note linking to the issue for future continuity"
  ]
}
```

**Paste-ready fallback (no gh, or auto:false):**
```jsonc
{
  "filed": false,
  "method": "paste-ready",
  "type": "bug",
  "labels": ["bug", "agent-filed"],
  "title": "...",
  "body": "...",
  "url": "https://github.com/Lukas-io/flutter_network_mcp/issues/new?title=...&body=...&labels=...",
  "nextSteps": [
    "Tell the user to open the deep-link URL — title + body + labels are pre-filled",
    "Install `gh` (https://cli.github.com/) + `gh auth login` to enable one-call filing next time"
  ]
}
```

## Pairs well with

- `network_status` — pull the `mcp` block + alerts state into the issue body for crucial version + state context.
- `alerts_drain` — when a stuck pending alert reveals something off about the MCP's detection.
- `audit show --signature <sig>` — pasting the sig + audit entry into the body anchors the report to a specific crash event.

## Example

```
> report_issue type:"bug" title:"network_summarize p95 is null when only 1 request"
   body:"network_summarize with only 1 captured request returns p95LatencyMs as the same value as p50LatencyMs which seems wrong — expected the float midpoint. Tool call: network_summarize sinceMs:60000. Response p50:240 p95:240."
< {filed:true, url:"https://github.com/.../issues/47", labels:["bug","agent-filed"]}
> # the agent: "I filed issue #47 to track this — https://github.com/.../47"
```
