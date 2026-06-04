import 'dart:convert';
import 'dart:io' as io;

import 'package:args/args.dart';

import '../util/data_dir.dart';
import 'audit_log.dart';

/// `flutter_network_mcp audit ...` — the user-facing surface for the
/// tamper-evident telemetry audit log.
///
/// Three actions:
/// - `audit verify` — walks the hash chain, reports intact / broken.
/// - `audit show` — decodes + pretty-prints every payload.
/// - `audit show --since <duration>` — last N days/hours/minutes.
/// - `audit show --signature <sig>` — only matching signature field.
///
/// User-initiated. The MCP server itself never calls this.
Future<void> runAudit(List<String> args) async {
  if (args.isEmpty) {
    _printUsage();
    io.exitCode = 64;
    return;
  }
  final action = args.first;
  final actionArgs = args.skip(1).toList();
  switch (action) {
    case 'verify':
      return _runVerify(actionArgs);
    case 'show':
      return _runShow(actionArgs);
    default:
      io.stderr.writeln(
        'flutter_network_mcp audit: unknown action "$action". Expected '
        'verify | show.',
      );
      _printUsage();
      io.exitCode = 64;
      return;
  }
}

Future<void> _runVerify(List<String> args) async {
  final dataDir = resolveCandidateDataDir();
  if (dataDir == null) {
    io.stderr.writeln(
      'flutter_network_mcp audit verify: could not resolve data dir. '
      'Set FLUTTER_NETWORK_MCP_DATA_DIR or your shell HOME.',
    );
    io.exitCode = 73;
    return;
  }
  final result = AuditLog.verify(dataDir);
  if (result.totalEntries == 0) {
    io.stdout.writeln(
      'flutter_network_mcp audit verify: 0 entries. The audit log doesn\'t '
      'exist yet (no telemetry written). Path: $dataDir/${AuditLog.fileName}',
    );
    return;
  }
  if (result.intact) {
    io.stdout.writeln(
      'flutter_network_mcp audit verify: ${result.totalEntries} entries, '
      'chain intact.\n'
      '  First entry: ${result.firstTs?.toIso8601String()}\n'
      '  Last entry:  ${result.lastTs?.toIso8601String()}\n'
      'Use `flutter_network_mcp audit show` to view payloads.',
    );
    return;
  }
  io.stderr.writeln(
    'flutter_network_mcp audit verify: chain broken at entry '
    '${result.brokenAtIndex} (reason: ${result.brokenReason}).\n'
    '  Total entries: ${result.totalEntries}\n'
    '  Entries before ${result.brokenAtIndex} are intact. '
    'After ${result.brokenAtIndex}, the chain cannot be verified.',
  );
  io.exitCode = 70;
}

Future<void> _runShow(List<String> args) async {
  final parser = ArgParser()
    ..addOption(
      'since',
      help: 'Relative duration filter, e.g. 7d, 24h, 30m. Default: all.',
    )
    ..addOption(
      'signature',
      help: 'Only entries with this exact signature value in the payload.',
    )
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
    io.stdout.writeln('flutter_network_mcp audit show — usage:');
    io.stdout.writeln(parser.usage);
    return;
  }

  final dataDir = resolveCandidateDataDir();
  if (dataDir == null) {
    io.stderr.writeln(
      'flutter_network_mcp audit show: could not resolve data dir.',
    );
    io.exitCode = 73;
    return;
  }

  DateTime? sinceCutoff;
  final sinceRaw = parsed['since'] as String?;
  if (sinceRaw != null && sinceRaw.isNotEmpty) {
    final dur = _parseDuration(sinceRaw);
    if (dur == null) {
      io.stderr.writeln(
        'flutter_network_mcp audit show: --since must be of the form '
        '<n>d | <n>h | <n>m (e.g. 7d, 24h). Got: "$sinceRaw".',
      );
      io.exitCode = 64;
      return;
    }
    sinceCutoff = DateTime.now().toUtc().subtract(dur);
  }
  final signatureFilter = parsed['signature'] as String?;

  final entries = AuditLog.readAll(dataDir);
  if (entries.isEmpty) {
    io.stdout.writeln(
      'flutter_network_mcp audit show: no entries. Audit log: '
      '$dataDir/${AuditLog.fileName}',
    );
    return;
  }

  var shown = 0;
  for (var i = 0; i < entries.length; i++) {
    final entry = entries[i];
    if (entry == null) {
      io.stderr.writeln('# entry $i: malformed (skipped)');
      continue;
    }
    if (sinceCutoff != null && entry.ts.isBefore(sinceCutoff)) continue;
    final payloadJson = entry.decodePayload();
    if (signatureFilter != null) {
      Map<String, Object?>? decoded;
      try {
        decoded = jsonDecode(payloadJson) as Map<String, Object?>;
      } catch (_) {/* keep null */}
      if (decoded == null || decoded['signature'] != signatureFilter) {
        continue;
      }
    }
    shown++;
    io.stdout.writeln('---');
    io.stdout.writeln('# entry $i  ts=${entry.ts.toIso8601String()}');
    io.stdout.writeln('# this_hash=${entry.thisHash.substring(0, 12)}…');
    try {
      final pretty = const JsonEncoder.withIndent('  ')
          .convert(jsonDecode(payloadJson));
      io.stdout.writeln(pretty);
    } catch (_) {
      io.stdout.writeln(payloadJson);
    }
  }
  io.stdout.writeln('---');
  io.stdout.writeln(
    'flutter_network_mcp audit show: $shown of ${entries.length} entries '
    'displayed${sinceCutoff != null || signatureFilter != null ? " (filtered)" : ""}.',
  );
}

void _printUsage() {
  io.stderr.writeln('flutter_network_mcp audit <verify|show> [args]');
  io.stderr.writeln(
    '  verify              walk the hash chain; report intact / broken\n'
    '  show                decode + pretty-print every audit entry\n'
    '  show --since 7d     filter to the last 7 days (or h/m units)\n'
    '  show --signature S  filter to entries whose payload signature matches',
  );
}

/// Parses `7d`, `24h`, `30m` into a Duration. Returns null on garbage.
Duration? _parseDuration(String raw) {
  if (raw.length < 2) return null;
  final unit = raw[raw.length - 1];
  final numStr = raw.substring(0, raw.length - 1);
  final n = int.tryParse(numStr);
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
