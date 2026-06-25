// flutter_network_mcp telemetry collector (Cloudflare Worker + D1).
//
// Receives the two payload kinds the MCP binary ships to kCollectorEndpoint:
//   * usage rollups  (body.kind === "usage_rollup")  -> usage_rollups + tool_stats + tool_transitions
//   * crash reports  (anything else, has errorClass)  -> crashes
//
// Endpoints:
//   POST /v1/telemetry   accept a payload (this is the URL you bake into the binary)
//   GET  /               health check
//   GET  /v1/stats       quick per-tool rollup (JSON), so you can eyeball usage without wrangler
//
// No auth in v1: the only identifier is the one-way machine_hash. Add a shared
// secret / signature check later if abuse appears (the binary holds the public
// salt; you hold the HMAC secret on this side).

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === 'GET' && url.pathname === '/') {
      return text('flutter_network_mcp collector: ok');
    }

    if (request.method === 'GET' && url.pathname === '/v1/stats') {
      return handleStats(env);
    }

    if (request.method !== 'POST') {
      return json({ error: 'method not allowed' }, 405);
    }

    let payload;
    try {
      payload = await request.json();
    } catch (_) {
      return json({ error: 'invalid JSON body' }, 400);
    }

    const now = Date.now();
    try {
      if (payload && payload.kind === 'usage_rollup') {
        await insertUsageRollup(env.DB, payload, now);
        return json({ ok: true, kind: 'usage_rollup' }, 202);
      }
      await insertCrash(env.DB, payload || {}, now);
      return json({ ok: true, kind: 'crash' }, 202);
    } catch (e) {
      return json({ error: String(e && e.message ? e.message : e) }, 500);
    }
  },
};

async function insertCrash(db, p, now) {
  await db
    .prepare(
      `INSERT INTO crashes
        (received_at, reported_at, machine_hash, version, commit_sha, is_aot,
         os, dart, error_class, error_message, signature, stack_head)
       VALUES (?,?,?,?,?,?,?,?,?,?,?,?)`,
    )
    .bind(
      now,
      p.reportedAt ?? null,
      p.machineHash ?? null,
      p.version ?? null,
      p.commit ?? null,
      p.isAot ? 1 : 0,
      p.os ?? null,
      p.dart ?? null,
      p.errorClass ?? null,
      p.errorMessage ?? null,
      p.signature ?? null,
      JSON.stringify(p.stackHead ?? []),
    )
    .run();
}

async function insertUsageRollup(db, p, now) {
  const w = p.window ?? {};
  const res = await db
    .prepare(
      `INSERT INTO usage_rollups
        (received_at, reported_at, machine_hash, version, commit_sha, is_aot,
         os, dart, first_event_ms, last_event_ms, to_event_id, total_events,
         total_turns)
       VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)`,
    )
    .bind(
      now,
      p.reportedAt ?? null,
      p.machineHash ?? null,
      p.version ?? null,
      p.commit ?? null,
      p.isAot ? 1 : 0,
      p.os ?? null,
      p.dart ?? null,
      w.firstEventMs ?? null,
      w.lastEventMs ?? null,
      w.toEventId ?? null,
      p.totalEvents ?? null,
      p.totalTurns ?? null,
    )
    .run();

  const rollupId = res.meta.last_row_id;
  const machine = p.machineHash ?? null;
  const stmts = [];

  for (const t of p.tools ?? []) {
    stmts.push(
      db
        .prepare(
          `INSERT INTO tool_stats
            (rollup_id, machine_hash, tool, count, ok, error, empty,
             error_rate, empty_rate, p50_ms, p95_ms, avg_result_bytes,
             estimated_tokens, degraded)
           VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)`,
        )
        .bind(
          rollupId,
          machine,
          t.tool,
          t.count ?? 0,
          t.ok ?? 0,
          t.error ?? 0,
          t.empty ?? 0,
          t.errorRate ?? 0,
          t.emptyRate ?? 0,
          t.p50Ms ?? null,
          t.p95Ms ?? null,
          t.avgResultBytes ?? null,
          t.totalEstimatedTokens ?? null,
          t.degraded ?? 0,
        ),
    );

    for (const [kind, n] of Object.entries(t.errorKinds ?? {})) {
      stmts.push(
        db
          .prepare(
            `INSERT INTO tool_error_kinds
              (rollup_id, machine_hash, tool, error_kind, count)
             VALUES (?,?,?,?,?)`,
          )
          .bind(rollupId, machine, t.tool, kind, n ?? 0),
      );
    }
  }

  for (const tr of p.transitions ?? []) {
    stmts.push(
      db
        .prepare(
          `INSERT INTO tool_transitions
            (rollup_id, machine_hash, from_tool, from_outcome, to_tool, count)
           VALUES (?,?,?,?,?,?)`,
        )
        .bind(
          rollupId,
          machine,
          tr.from ?? null,
          tr.fromOutcome ?? null,
          tr.to ?? null,
          tr.count ?? 0,
        ),
    );
  }

  for (const sc of p.selfCorrection ?? []) {
    stmts.push(
      db
        .prepare(
          `INSERT INTO tool_self_correction
            (rollup_id, machine_hash, tool, signal, occurrences, recovered)
           VALUES (?,?,?,?,?,?)`,
        )
        .bind(
          rollupId,
          machine,
          sc.tool ?? null,
          sc.signal ?? null,
          sc.occurrences ?? 0,
          sc.recovered ?? 0,
        ),
    );
  }

  if (stmts.length) await db.batch(stmts);
}

async function handleStats(env) {
  const r = await env.DB.prepare(
    `SELECT tool,
            SUM(count)  AS calls,
            SUM(error)  AS errors,
            SUM(empty)  AS empties
       FROM tool_stats
      GROUP BY tool
      ORDER BY calls DESC
      LIMIT 50`,
  ).all();
  return json({ tools: r.results ?? [] });
}

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'content-type': 'application/json' },
  });
}

function text(body, status = 200) {
  return new Response(body, {
    status,
    headers: { 'content-type': 'text/plain' },
  });
}
