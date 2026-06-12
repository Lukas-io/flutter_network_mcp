import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../config/capabilities.dart';
import '../config/session_filters.dart';
import '../state/session.dart';
import '../storage/captures_db.dart';
import '../util/filters.dart';
import '../util/scope.dart';
import 'result.dart';

const int _kMessageTruncateBytes = 2048;
const int _kSevereLevel = 1200;

final logsTailTool = Tool(
  name: 'logs_tail',
  description:
      'Read recent app logs — the running app\'s `print`, `developer.log`, '
      'stdout, and stderr. Use this when correlating a log line with a '
      'nearby HTTP request, chasing an exception spotted via alerts_drain, '
      'or just inspecting what the app is doing. Newest-first, '
      'cursor-paginated (pass `since` for incremental polling). Live mode '
      'reads from an in-memory ring buffer (size configurable via '
      '`FLUTTER_NETWORK_MCP_LOG_BUFFER`, default 500); after session_open it '
      'reads persisted log_records for the viewed session instead. Filter by '
      '`levelMin` to suppress noisy info logs, or `messageContains` (one tag '
      'or a list of tags, OR-matched) to grep the message body when loggers '
      'are unnamed.',
  inputSchema: Schema.object(
    properties: {
      'sessionId': Schema.int(
        description:
            'Which session\'s logs to read. Omit to auto-resolve: explicit '
            'view (session_open) → sole attached session → error if 2+ '
            'attached.',
      ),
      'appNameContains': Schema.string(
        description:
            'Alternative to sessionId — case-insensitive substring on a '
            'currently-attached app name.',
      ),
      'since': Schema.int(
        description:
            'Cursor — local id from a prior nextCursor. Omit to fetch the '
            'most recent up to `limit`.',
      ),
      'levelMin': Schema.int(
        description:
            'Minimum severity (package:logging scale 0–2000; WARNING=900, '
            'SEVERE=1200). Applies only to Logging records, not stdout/stderr.',
      ),
      'loggerContains': Schema.string(
        description: 'Substring match (case-insensitive) on logger name.',
      ),
      'messageContains': Schema.list(
        description:
            'Substring match(es) (case-insensitive) on the log MESSAGE body, '
            'OR-combined. Use this when loggers are unnamed (so loggerContains '
            'matches nothing). Pass one tag, e.g. ["[EventTracker]"], or '
            'several to get them all in one call, e.g. '
            '["EventTracker","KycTier"]. Filtering happens server-side, so it '
            'cuts response size before it reaches you.',
        items: Schema.string(),
      ),
      'source': Schema.string(
        description: '"logging" | "stdout" | "stderr". Omit for all sources.',
      ),
      'isolateId': Schema.string(
        description:
            'Optional: restrict to one isolate within the session. Get the id '
            'from network_status.attached[].isolates[]. Omit to merge every '
            'isolate (the default). VM-level events with no isolate context '
            '(rare on these streams) are EXCLUDED when this filter is set.',
      ),
      'limit': Schema.int(
        description: 'Max records returned (default 100, hard cap 500). Newest-first.',
      ),
    },
  ),
);

FutureOr<CallToolResult> logsTail(CallToolRequest request) async {
  final caps = CapabilityConfig.instance;
  final args = request.arguments ?? const <String, Object?>{};
  final (scope, scopeErr) = resolveScope(args);
  if (scopeErr != null) return scopeErr;
  scope!;

  // Sticky defaults (#18): inherit from session_configure when an arg is
  // omitted; an explicitly-passed arg (even null) wins for this call.
  final sf = SessionFilters.instance;
  final sinceId = args['since'] as int?;
  final levelMin =
      args.containsKey('levelMin') ? args['levelMin'] as int? : sf.levelMin;
  final loggerContains = args.containsKey('loggerContains')
      ? args['loggerContains'] as String?
      : sf.loggerContains;
  final messageContains = args.containsKey('messageContains')
      ? readStringList(args['messageContains'])
      : sf.messageContains;
  final source =
      args.containsKey('source') ? args['source'] as String? : sf.source;
  final isolateFilter = args['isolateId'] as String?;
  final limit = clampLimit(args['limit'] as int?, fallback: 100, hardMax: 500);

  if (!scope.isLive) {
    final sid = scope.sessionId;
    try {
      final rows = CapturesDao().queryLogs(
        sessionId: sid,
        sinceId: sinceId,
        levelMin: levelMin,
        loggerContains: loggerContains,
        messageContains: messageContains,
        source: source,
        isolateId: isolateFilter,
        limit: limit,
      );
      final out = <Map<String, Object?>>[];
      int? maxId;
      int severeCount = 0;
      for (final r in rows) {
        final id = r['id'] as int;
        if (maxId == null || id > maxId) maxId = id;
        final lvl = r['level'] as int?;
        if (lvl != null && lvl >= _kSevereLevel) severeCount++;
        out.add(_historyEntry(r));
      }
      return jsonResult(_buildResponse(
        scope: scope,
        source: 'history',
        entries: out,
        nextCursor: maxId,
        bufferSize: null,
        bufferCapacity: null,
        streamActive: null,
        severeCount: severeCount,
        levelMin: levelMin,
        loggerContains: loggerContains,
        messageContains: messageContains,
        sourceFilter: source,
        caps: caps,
      ), scopeSessionId: scope.sessionId);
    } catch (e) {
      return errorResult('history query failed: $e', extra: {
        'sessionId': sid,
        'nextSteps': const [
          'session_close — return to live mode',
          'session_list — confirm the viewed session exists',
        ],
      });
    }
  }

  // Live mode — read this attached session's own ring buffer.
  final attached = SessionRegistry.instance.attachedById(scope.sessionId)!;
  final entries = attached.logBuffer.tail(
    sinceId: sinceId,
    levelMin: levelMin,
    loggerContains: loggerContains,
    messageContains: messageContains,
    sourceContains: source,
    isolateId: isolateFilter,
    limit: limit,
  );
  final out = <Map<String, Object?>>[];
  int? maxId;
  int severeCount = 0;
  for (final e in entries) {
    if (maxId == null || e.id > maxId) maxId = e.id;
    if ((e.level ?? 0) >= _kSevereLevel) severeCount++;
    out.add(_liveEntry(e));
  }
  return jsonResult(_buildResponse(
    scope: scope,
    source: 'live',
    entries: out,
    nextCursor: maxId,
    bufferSize: attached.logBuffer.length,
    bufferCapacity: attached.logBuffer.capacity,
    streamActive: attached.logStream.isActive,
    severeCount: severeCount,
    levelMin: levelMin,
    loggerContains: loggerContains,
    messageContains: messageContains,
    sourceFilter: source,
    caps: caps,
  ), scopeSessionId: scope.sessionId);
}

Map<String, Object?> _historyEntry(Map<String, Object?> r) {
  final msg = (r['message'] as String?) ?? '';
  final truncated = msg.length > _kMessageTruncateBytes;
  return {
    'id': r['id'],
    'source': r['source'],
    if (r['isolate_id'] != null) 'isolateId': r['isolate_id'],
    if (r['timestamp_ms'] != null) 'timestampMs': r['timestamp_ms'],
    if (r['level'] != null) 'level': r['level'],
    if (r['logger'] != null) 'loggerName': r['logger'],
    'message': truncated ? msg.substring(0, _kMessageTruncateBytes) : msg,
    if (truncated) 'truncated': true,
    if (truncated) 'totalLength': msg.length,
    if (r['error'] != null) 'error': r['error'],
    if (r['stack_trace'] != null) 'stackTrace': r['stack_trace'],
  };
}

Map<String, Object?> _liveEntry(dynamic e) {
  final msg = e.message as String;
  final truncated = msg.length > _kMessageTruncateBytes;
  return {
    'id': e.id,
    'source': e.source,
    if (e.isolateId != null) 'isolateId': e.isolateId,
    if (e.timestampMs != null) 'timestampMs': e.timestampMs,
    if (e.level != null) 'level': e.level,
    if (e.loggerName != null) 'loggerName': e.loggerName,
    'message': truncated ? msg.substring(0, _kMessageTruncateBytes) : msg,
    if (truncated) 'truncated': true,
    if (truncated) 'totalLength': msg.length,
    if (e.error != null) 'error': e.error,
    if (e.stackTrace != null) 'stackTrace': e.stackTrace,
  };
}

Map<String, Object?> _buildResponse({
  required Scope scope,
  required String source,
  required List<Map<String, Object?>> entries,
  required int? nextCursor,
  required int? bufferSize,
  required int? bufferCapacity,
  required bool? streamActive,
  required int severeCount,
  required int? levelMin,
  required String? loggerContains,
  required List<String>? messageContains,
  required String? sourceFilter,
  required CapabilityConfig caps,
}) {
  final sessionId = scope.sessionId;
  final filters =
      _filterDesc(levelMin, loggerContains, messageContains, sourceFilter);
  // Buffer is "near capacity" at 80% full; reads its real configured size
  // (FLUTTER_NETWORK_MCP_LOG_BUFFER / per-attach override), not a hardcoded
  // 500, so the warning stays correct when the user bumps the buffer (#21).
  final nearCapacity = source == 'live' &&
      bufferSize != null &&
      bufferCapacity != null &&
      bufferSize >= (bufferCapacity * 0.8).floor();
  final summary = entries.isEmpty
      ? (source == 'live' && streamActive == false
          ? 'Log stream not active — buffer is empty.'
          : 'No log records${filters.isEmpty ? "" : " matching $filters"} in $source mode (session $sessionId${scope.appName != null ? ", ${scope.appName}" : ""}).')
      : '${entries.length} record(s) from $source session $sessionId'
          '${scope.appName != null ? " (${scope.appName})" : ""}'
          '${severeCount > 0 ? ", $severeCount severe (level ≥ 1200)" : ""}'
          '${filters.isEmpty ? "" : "; filtered by $filters"}.';

  final warnings = <String>[];
  if (source == 'live' && streamActive == false) {
    warnings.add('Log stream is not subscribed — buffer will stay empty. Re-attach to start log capture.');
  }
  if (entries.isEmpty && filters.isNotEmpty) {
    warnings.add('No matches — try widening levelMin / dropping loggerContains.');
  }
  if (nearCapacity) {
    warnings.add('Ring buffer near capacity ($bufferSize / $bufferCapacity); '
        'older records may have rotated out. Raise '
        'FLUTTER_NETWORK_MCP_LOG_BUFFER (or re-attach with a larger '
        'logBufferSize), or use history mode (session_open) for the full '
        'record.');
  }

  final nextSteps = <String>[];
  if (entries.isEmpty) {
    nextSteps.add('Drive the app to generate logs');
    if (filters.isNotEmpty) {
      nextSteps.add('Drop filters to broaden the search');
    }
  } else {
    if (severeCount > 0 && caps.isEnabled(Category.alerts)) {
      nextSteps.add('alerts_drain — see what the detector flagged for these severe records');
    }
    if (nextCursor != null) {
      nextSteps.add('logs_tail since:$nextCursor — page incrementally on next call');
    }
  }
  if (nearCapacity) {
    nextSteps.add('Buffer is ${((bufferSize / bufferCapacity) * 100).round()}% '
        'full; raise FLUTTER_NETWORK_MCP_LOG_BUFFER if you are missing older '
        'records');
  }

  return {
    'source': source,
    'scope': scope.toBlock(),
    'sessionId': sessionId,
    'summary': summary,
    'count': entries.length,
    if (bufferSize != null) 'bufferSize': bufferSize,
    if (bufferCapacity != null) 'bufferCapacity': bufferCapacity,
    if (streamActive != null) 'streamActive': streamActive,
    if (severeCount > 0) 'severeCount': severeCount,
    'nextCursor': nextCursor,
    if (warnings.isNotEmpty) 'warnings': warnings,
    'nextSteps': nextSteps,
    'entries': entries,
  };
}

String _filterDesc(
  int? levelMin,
  String? loggerContains,
  List<String>? messageContains,
  String? source,
) {
  final parts = <String>[];
  if (levelMin != null) parts.add('level≥$levelMin');
  if (loggerContains != null && loggerContains.isNotEmpty) parts.add('logger~"$loggerContains"');
  final msgTerms =
      messageContains?.where((t) => t.trim().isNotEmpty).toList() ?? const [];
  if (msgTerms.isNotEmpty) {
    parts.add(msgTerms.length == 1
        ? 'message~"${msgTerms.single}"'
        : 'message~any[${msgTerms.map((t) => '"$t"').join(', ')}]');
  }
  if (source != null && source.isNotEmpty) parts.add('source=$source');
  return parts.join(', ');
}
