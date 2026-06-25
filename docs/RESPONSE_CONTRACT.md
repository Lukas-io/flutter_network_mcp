# Agent-intuitive response contract

For an agent, the tool **response is the entire interface**. Between two calls
it has only the JSON you handed back: no memory, no screen, no intuition. So
every response must let the agent answer three questions on its own:

1. **What state am I in?** (ok / degraded / error)
2. **Why?** (no data vs wrong input vs broken vs unresponsive)
3. **What are my best next moves?**

This file is the shared shape every tool returns so the surface is *learnable*:
an agent that learns the pattern on one tool can apply it to all of them.

## Success shape

```jsonc
{
  "source": "live" | "history" | "live-db-fallback",
  "summary": "one human/agent-readable sentence: what happened",
  "count": 12,                       // when returning a collection
  "partial": true,                   // optional: some items were skipped
  "degraded": true,                  // optional: a fallback path was used
  "warnings": ["why something is off / why a result is empty"],
  "nextSteps": ["the affordances — the agent's navigation"],
  "<data>": []                       // the actual payload (requests, rows, ...)
}
```

- **`summary`** answers "what state". **`warnings`** answer "why".
  **`nextSteps`** answer "what next". None are optional thinking — they ARE
  the UX.
- **Distinguish empty causes.** "0 new since last call" / "0 ever captured" /
  "filtered everything out" / "term did not match" are four different next
  actions. Never collapse them into a bare empty list.

## Error shape

Built by `errorResult(message, kind: ..., extra: {...})`:

```jsonc
{
  "error": "human-readable message",
  "errorKind": "unresponsive_vm",    // stable, branchable — see ErrorKind
  "nextSteps": ["the recovery path"],
  "<self-correction>": {}            // schema, availableHosts, etc.
}
```

### `errorKind` taxonomy (`lib/src/tools/error_kind.dart`)

Wire strings are a contract; **never rename**. New kinds are additive; an
agent that sees an unknown kind treats it as `internal`.

| wire | meaning | recovery |
|------|---------|----------|
| `bad_argument` | missing/invalid arg the agent passed | fix the call |
| `not_found` | id/session/request doesn't exist | re-list |
| `no_session` | nothing attached / scope unresolved | attach / pass sessionId |
| `unresponsive_vm` | RPC timed out (app paused/backgrounded, DDS wedged) | retry, or read from DB |
| `bad_query` | malformed SQL / search | use the inline schema/terms, retry |
| `capability_disabled` | tool gated off | enable it / use another tool |
| `internal` | unexpected | report |

## The error-resistance ladder

Push every tool as high up this ladder as it can go, **consistently**:

1. **Prevent** — validate args; self-correct (return schema on bad SQL,
   available hosts on empty search) so the next call succeeds.
2. **Tolerate** — one bad item never fails the batch (per-item try/catch,
   `partial: true`).
3. **Bound** — nothing hangs (every VM RPC has a deadline; `VmRpcTimeoutException`).
4. **Degrade** — primary fails -> automatic fallback (`degradedResult`,
   `source: "live-db-fallback"`), never dead-end.
5. **Guide** — when you can't degrade, `nextSteps` say exactly what to try.

Inconsistency is itself an error source: if one tool degrades to the DB on
failure, all of them must, or the agent's learned model breaks.
