import 'dart:convert';
import 'dart:io' as io;

import 'package:args/args.dart';

import '../storage/captures_db.dart';
import '../storage/database.dart';
import 'usage_reporter.dart';

/// `flutter_network_mcp usage [...]` — the transparency surface for the local
/// tool-usage record (issue #79, Phase 1). Lets the user SEE exactly what is
/// being captured (tool names, arg KEYS, outcomes, durations, sizes — never
/// values), so the "default-on but auditable" pact holds for usage data the
/// same way `audit show` holds for crash telemetry.
///
/// User-initiated. The MCP server never calls this.
///
/// - `usage`               per-tool summary with outcome breakdown.
/// - `usage --show`        recent raw events.
/// - `usage --since 7d`    window filter (also `h` / `m` units).
/// - `usage --json`        machine-readable output.
/// - `usage ship`          ship the aggregate rollup (Phase 3, #79).
Future<void> runUsage(List<String> args) async {
  if (args.isNotEmpty && args.first == 'ship') {
    return _runShip(args.skip(1).toList());
  }

  final parser = ArgParser()
    ..addFlag('show',
        negatable: false, help: 'List recent raw events instead of the summary.')
    ..addOption('since', help: 'Relative window: 7d, 24h, 30m. Default: all.')
    ..addOption('limit', help: 'Max raw events with --show (default 50).')
    ..addFlag('json', negatable: false, help: 'Emit JSON instead of text.')
    ..addFlag('help', abbr: 'h', negatable: false);

  final ArgResults parsed;
  try {
    parsed = parser.parse(args);
  } on FormatException catch (e) {
    io.stderr.writeln('Error: ${e.message}');
    io.stderr.writeln(parser.usage);
    io.exitCode = 64;
    return;
  }
  if (parsed['help'] == true) {
    io.stdout.writeln('flutter_network_mcp usage [--show] [--since 7d] '
        '[--limit N] [--json]');
    io.stdout.writeln('flutter_network_mcp usage ship [--dry-run] [--json]');
    io.stdout.writeln(parser.usage);
    io.stdout.writeln(
      '\nLocal, privacy-safe record of which tools agents call. Stores the '
      'tool name, the arg KEYS passed (never their values), an outcome '
      '(ok/error/empty), a duration, and a result size. The default views '
      'are local-only; `usage ship` folds the events into an aggregate and '
      'records it to the audit log (and the collector, when configured). '
      'Opt out with FLUTTER_NETWORK_MCP_NO_USAGE=true (or the broader '
      'FLUTTER_NETWORK_MCP_NO_TELEMETRY=true).',
    );
    return;
  }

  int? sinceMs;
  final sinceRaw = parsed['since'] as String?;
  if (sinceRaw != null && sinceRaw.isNotEmpty) {
    final dur = _parseDuration(sinceRaw);
    if (dur == null) {
      io.stderr.writeln(
        'flutter_network_mcp usage: --since must be <n>d | <n>h | <n>m '
        '(e.g. 7d, 24h). Got: "$sinceRaw".',
      );
      io.exitCode = 64;
      return;
    }
    sinceMs = DateTime.now().millisecondsSinceEpoch - dur.inMilliseconds;
  }

  try {
    CapturesDatabase.open();
  } catch (e) {
    io.stderr.writeln('flutter_network_mcp usage: could not open the DB ($e).');
    io.exitCode = 73;
    return;
  }

  final dao = CapturesDao();
  final total = dao.toolEventCount();
  final asJson = parsed['json'] == true;

  if (parsed['show'] == true) {
    final limit = int.tryParse((parsed['limit'] as String?) ?? '') ?? 50;
    final events = dao.recentToolEvents(sinceMs: sinceMs, limit: limit);
    if (asJson) {
      io.stdout.writeln(jsonEncode({'total': total, 'events': events}));
      return;
    }
    if (events.isEmpty) {
      io.stdout.writeln('No tool events recorded yet.');
      return;
    }
    for (final e in events) {
      final ts = DateTime.fromMillisecondsSinceEpoch(e['ts_ms'] as int)
          .toIso8601String();
      io.stdout.writeln(
        '$ts  ${(e['tool'] as String).padRight(20)}  '
        '${(e['outcome'] as String).padRight(6)}  '
        '${e['duration_ms'] ?? '?'}ms  ${e['result_bytes'] ?? '?'}b  '
        'corr=${e['correlation_id']}  keys=${e['arg_keys'] ?? '[]'}',
      );
    }
    io.stdout.writeln('--- ${events.length} event(s) shown, $total total.');
    return;
  }

  // Default: per-tool summary with outcome breakdown.
  final counts = dao.toolEventCounts(sinceMs: sinceMs);
  if (asJson) {
    io.stdout.writeln(jsonEncode({'total': total, 'counts': counts}));
    return;
  }
  if (counts.isEmpty) {
    io.stdout.writeln(
      'No tool events recorded yet${sinceMs != null ? " in this window" : ""}. '
      '(Capture is on by default; opt out with '
      'FLUTTER_NETWORK_MCP_NO_USAGE=true.)',
    );
    return;
  }

  final perTool = <String, Map<String, int>>{};
  for (final row in counts) {
    final tool = row['tool'] as String;
    final outcome = row['outcome'] as String;
    (perTool[tool] ??= {})[outcome] = row['count'] as int;
  }
  final sorted = perTool.entries.toList()
    ..sort((a, b) => _sum(b.value).compareTo(_sum(a.value)));

  io.stdout.writeln(
    'Tool usage ($total event(s) total'
    '${sinceMs != null ? ", filtered window" : ""}):',
  );
  for (final entry in sorted) {
    final breakdown = entry.value.entries.map((e) => '${e.key}=${e.value}').join(' ');
    io.stdout.writeln(
      '  ${entry.key.padRight(22)} ${_sum(entry.value).toString().padLeft(5)}   ($breakdown)',
    );
  }
}

int _sum(Map<String, int> m) => m.values.fold(0, (a, b) => a + b);

/// `flutter_network_mcp usage ship` (issue #79, Phase 3). Folds every event
/// since the stored watermark into one privacy-safe aggregate, appends it
/// to the tamper-evident telemetry audit log, and POSTs to the collector
/// when one is configured. Idempotent; run it as often as you like.
Future<void> _runShip(List<String> args) async {
  final parser = ArgParser()
    ..addFlag('dry-run',
        negatable: false,
        help: 'Build + print the rollup without writing or sending it.')
    ..addFlag('json',
        negatable: false, help: 'Emit the rollup payload + result as JSON.')
    ..addFlag('help', abbr: 'h', negatable: false);

  final ArgResults parsed;
  try {
    parsed = parser.parse(args);
  } on FormatException catch (e) {
    io.stderr.writeln('Error: ${e.message}');
    io.stderr.writeln(parser.usage);
    io.exitCode = 64;
    return;
  }
  if (parsed['help'] == true) {
    io.stdout.writeln('flutter_network_mcp usage ship [--dry-run] [--json]');
    io.stdout.writeln(parser.usage);
    io.stdout.writeln(
      '\nShips an AGGREGATE rollup of tool usage (per-tool counts, outcome + '
      'latency stats, tool-to-next-tool transitions), never raw events. The '
      'exact payload is appended to the hash-chained telemetry audit log '
      'first, then POSTed to the collector when one is baked in (audit-log-'
      'only until then). A stored high-watermark makes re-runs idempotent. '
      'Opt out with FLUTTER_NETWORK_MCP_NO_USAGE=true.',
    );
    return;
  }

  final dryRun = parsed['dry-run'] == true;
  final asJson = parsed['json'] == true;
  final result = await UsageReporter.ship(dryRun: dryRun);

  if (asJson) {
    io.stdout.writeln(jsonEncode({
      'shipped': result.shipped,
      'dryRun': result.dryRun,
      'events': result.events,
      'fromEventId': result.fromEventId,
      'toEventId': result.toEventId,
      'posted': result.posted,
      'message': result.message,
      if (result.payloadJson != null)
        'payload': jsonDecode(result.payloadJson!),
    }));
    return;
  }

  io.stdout.writeln('flutter_network_mcp usage ship: ${result.message}');
  if (result.payloadJson != null && dryRun) {
    io.stdout.writeln(const JsonEncoder.withIndent('  ')
        .convert(jsonDecode(result.payloadJson!)));
  } else if (result.shipped) {
    io.stdout.writeln(
      '  events ${result.fromEventId + 1}..${result.toEventId} '
      '(${result.events} total). Inspect the exact rollup with: '
      'flutter_network_mcp audit show --since 1h',
    );
  }
}

/// Parses `7d`, `24h`, `30m` into a Duration. Returns null on garbage.
Duration? _parseDuration(String raw) {
  if (raw.length < 2) return null;
  final unit = raw[raw.length - 1];
  final n = int.tryParse(raw.substring(0, raw.length - 1));
  if (n == null || n < 0) return null;
  switch (unit) {
    case 'd':
      return Duration(days: n);
    case 'h':
      return Duration(hours: n);
    case 'm':
      return Duration(minutes: n);
    default:
      return null;
  }
}
