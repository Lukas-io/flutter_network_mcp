import 'dart:async';
import 'dart:io' as io;

import 'package:dart_mcp/server.dart';

import '../vm/dtd_discovery.dart';
import 'result.dart';

final networkDiscoverDtdTool = Tool(
  name: 'network_discover_dtd',
  description:
      'List Dart Tooling Daemon (DTD) instances on this machine so you can '
      'pick one to attach to without the user pasting a URI. Reads the '
      'standard package:dtd discovery directory; each entry includes the '
      'FULL ws:// URI with security token, plus workspaceRoot / pid / '
      'dartVersion / isLive / matchesCwd. Use when the MCP started '
      'without --dtd-uri or when multiple DTDs are running. Default scope '
      'is "live processes whose workspaceRoot matches cwd"; pass '
      '`cwdMatch:false` for everything, `includeStale:true` to include '
      'dead-pid candidates (auto-attach should usually skip those).',
  inputSchema: Schema.object(
    properties: {
      'cwdMatch': Schema.bool(
        description:
            'Restrict to candidates whose workspaceRoot equals the server\'s '
            'current working directory. Default true. Pass false to see '
            'every DTD on the machine.',
      ),
      'includeStale': Schema.bool(
        description:
            'Include candidates whose recorded pid no longer responds to '
            'the OS "exists?" probe (kill -0 on POSIX, tasklist on Windows). '
            'Stale discovery files persist when Dart processes die '
            'uncleanly. Default false — auto-attach should not use these.',
      ),
      'limit': Schema.int(
        description: 'Max candidates returned (default 5, hard cap 20). '
            'Sorted best-first: live > matchesCwd > newer epoch.',
      ),
    },
  ),
);

FutureOr<CallToolResult> networkDiscoverDtd(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final cwdMatch = (args['cwdMatch'] as bool?) ?? true;
  final includeStale = (args['includeStale'] as bool?) ?? false;
  final limitArg = (args['limit'] as int?) ?? 5;
  final limit = limitArg <= 0 ? 5 : (limitArg > 20 ? 20 : limitArg);

  final cwd = io.Directory.current.path;
  final discoveryDir = DtdDiscovery.discoveryDir();
  final all = DtdDiscovery.discover(cwd: cwd);

  // Apply filters in two stages so warnings can speak to what was dropped.
  final liveOnly = includeStale ? all : all.where((c) => c.isLive).toList();
  final cwdFiltered = cwdMatch
      ? liveOnly.where((c) => c.matchesCwd).toList()
      : liveOnly;
  final visible = cwdFiltered.take(limit).toList();

  final warnings = <String>[];
  if (discoveryDir == null) {
    warnings.add(
      'Could not resolve the package:dtd discovery directory for this '
      'platform (env var HOME / XDG_CONFIG_HOME / APPDATA missing). DTD '
      'auto-discovery is unavailable on this install.',
    );
  } else if (!io.Directory(discoveryDir).existsSync()) {
    warnings.add(
      'Discovery directory $discoveryDir does not exist. No DTDs have run '
      'on this machine since the last cleanup, or Dart SDK predates '
      'package:dtd discovery (Dart 3.5+).',
    );
  }
  if (all.isNotEmpty && liveOnly.isEmpty) {
    warnings.add(
      '${all.length} discovery file(s) found but every recorded pid is '
      'dead. The Dart processes likely exited; pass includeStale:true to '
      'inspect them anyway.',
    );
  }
  if (cwdMatch && liveOnly.isNotEmpty && cwdFiltered.isEmpty) {
    warnings.add(
      '${liveOnly.length} live DTD(s) found but none match cwd '
      '($cwd). Pass cwdMatch:false to see them.',
    );
  }
  if (cwdFiltered.length > limit) {
    warnings.add(
      '${cwdFiltered.length} matching candidates; only the top $limit '
      'shown. Raise limit (hard cap 20) to see more.',
    );
  }

  final summary = _buildSummary(
    visible: visible,
    totalFound: all.length,
    totalLive: liveOnly.length,
    cwdMatch: cwdMatch,
  );

  final recommended = visible.isEmpty ? null : visible.first.wsUri;

  final nextSteps = <String>[];
  if (recommended != null) {
    nextSteps.add('network_attach dtdUri:"$recommended" — attach to the recommended candidate');
    if (visible.length > 1) {
      nextSteps.add(
        'Pick another candidate by passing its wsUri to network_attach',
      );
    }
  } else if (cwdMatch && liveOnly.isNotEmpty) {
    nextSteps.add(
      'network_discover_dtd cwdMatch:false — see live DTDs from other projects',
    );
  } else if (!includeStale && all.isNotEmpty) {
    nextSteps.add(
      'network_discover_dtd includeStale:true — inspect dead-pid candidates',
    );
  } else {
    nextSteps.add('Launch a Flutter/Dart app (e.g. `flutter run`), then re-run this tool');
    nextSteps.add(
      'If you have a DTD URI from your IDE console, pass it directly: '
      'network_attach dtdUri:"<ws://...>"',
    );
  }

  return jsonResult({
    'summary': summary,
    if (discoveryDir != null) 'discoveryDir': discoveryDir,
    'cwd': cwd,
    'totalFound': all.length,
    'liveCount': liveOnly.length,
    'visibleCount': visible.length,
    if (recommended != null) 'recommended': recommended,
    'candidates': [for (final c in visible) c.toJson()],
    if (warnings.isNotEmpty) 'warnings': warnings,
    'nextSteps': nextSteps,
  });
}

String _buildSummary({
  required List<DtdCandidate> visible,
  required int totalFound,
  required int totalLive,
  required bool cwdMatch,
}) {
  if (visible.isEmpty && totalFound == 0) {
    return 'No DTD discovery files found.';
  }
  if (visible.isEmpty) {
    final scope = cwdMatch ? ' matching cwd' : '';
    return '$totalFound discovery file(s), $totalLive live, none$scope.';
  }
  final top = visible.first;
  return '${visible.length} candidate(s) returned (of $totalFound found, '
      '$totalLive live). Recommended: ${top.wsUri} '
      '(pid ${top.pid}${top.workspaceRoot != null ? ", ${top.workspaceRoot}" : ""}).';
}
