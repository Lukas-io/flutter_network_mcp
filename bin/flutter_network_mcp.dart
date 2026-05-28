import 'dart:io' as io;

import 'package:args/args.dart';
import 'package:flutter_network_mcp/src/auto_attach.dart';
import 'package:flutter_network_mcp/src/config/capabilities.dart';
import 'package:flutter_network_mcp/src/server.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:flutter_network_mcp/src/tools/alert_patterns.dart' as alert_patterns;

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption(
      'dtd-uri',
      help:
          'Default DTD WebSocket URI for network_attach. Falls back to the '
          'FLUTTER_NETWORK_MCP_DTD_URI environment variable.',
    )
    ..addOption(
      'data-dir',
      help:
          'Directory for captures.db. macOS default: '
          '~/Library/Application Support/flutter_network_mcp. '
          r'Linux default: $XDG_DATA_HOME/flutter_network_mcp or '
          '~/.local/share/flutter_network_mcp. Env-var fallback: '
          'FLUTTER_NETWORK_MCP_DATA_DIR.',
    )
    ..addOption(
      'capabilities',
      help:
          'Comma-separated allowlist of categories to enable. Options: '
          'http, sockets, logs, alerts, search, sessions, sql, admin. '
          'Lifecycle (status/attach/detach) is always on. Falls back to '
          'FLUTTER_NETWORK_MCP_CAPABILITIES. Mutually exclusive with --disable.',
    )
    ..addOption(
      'disable',
      help:
          'Comma-separated denylist of categories to disable. Same option '
          'set as --capabilities. Falls back to FLUTTER_NETWORK_MCP_DISABLE.',
    )
    ..addOption(
      'auto-attach',
      help:
          'Watch DTD for new apps and auto-attach them. Value is a '
          'comma-separated allowlist of case-insensitive substring '
          'patterns matched against the app name from DTD; only matching '
          'apps are auto-attached. Example: '
          '--auto-attach=sanga_mobile,sanga_driver. There is NO bool '
          'form — to enable auto-attach you MUST specify which apps. '
          'Absent or empty value disables. Apps already running at '
          'startup are NOT auto-attached (seed-and-skip). Manual '
          'network_detach survives — detached apps stay in the known '
          'set. Poll interval: FLUTTER_NETWORK_MCP_AUTO_ATTACH_POLL_MS '
          '(default 5000, clamped 1000–60000). Requires --dtd-uri or '
          'FLUTTER_NETWORK_MCP_DTD_URI. Env-var fallback: '
          'FLUTTER_NETWORK_MCP_AUTO_ATTACH=app1,app2.',
    )
    ..addFlag('help', abbr: 'h', negatable: false);

  final ArgResults results;
  try {
    results = parser.parse(args);
  } on FormatException catch (e) {
    io.stderr.writeln('Error: ${e.message}');
    io.stderr.writeln(parser.usage);
    io.exitCode = 64; // EX_USAGE
    return;
  }

  if (results['help'] == true) {
    io.stderr.writeln('flutter_network_mcp');
    io.stderr.writeln(parser.usage);
    return;
  }

  final env = io.Platform.environment;
  final dtdUri = (results['dtd-uri'] as String?) ??
      env['FLUTTER_NETWORK_MCP_DTD_URI'];
  final dataDir = results['data-dir'] as String?;
  final capabilities =
      (results['capabilities'] as String?) ?? env['FLUTTER_NETWORK_MCP_CAPABILITIES'];
  final disable = (results['disable'] as String?) ?? env['FLUTTER_NETWORK_MCP_DISABLE'];

  try {
    CapabilityConfig.install(
      CapabilityConfig.fromFlags(allowlist: capabilities, denylist: disable),
    );
  } on ArgumentError catch (e) {
    io.stderr.writeln('Error: ${e.message}');
    io.exitCode = 64;
    return;
  }

  try {
    CapturesDatabase.open(dataDir: dataDir);
  } on io.FileSystemException catch (e) {
    io.stderr.writeln(
      'flutter_network_mcp: cannot create data dir '
      '(${e.osError?.message ?? e.message}).\n'
      'Pass --data-dir <writable path> or set FLUTTER_NETWORK_MCP_DATA_DIR.',
    );
    io.exitCode = 73; // EX_CANTCREAT
    return;
  } on StateError catch (e) {
    // Thrown by CapturesDatabase.open() when every candidate failed.
    io.stderr.writeln('flutter_network_mcp: ${e.message}');
    io.exitCode = 73;
    return;
  }

  // Hydrate user-defined alert patterns from the DB so they fire from the
  // very first capture tick.
  try {
    alert_patterns.loadCustomPatternsFromDb();
  } catch (_) {/* table may be empty / freshly migrated */}

  FlutterNetworkMcpServer.stdio(defaultDtdUri: dtdUri);

  // Optional: watch DTD for new apps and auto-attach. CLI flag takes
  // priority; env var fallback is FLUTTER_NETWORK_MCP_AUTO_ATTACH=app1,app2.
  // Value is a comma-separated allowlist of substring patterns. Empty /
  // absent disables. No bool form — to enable auto-attach you must say
  // which apps it's allowed to grab.
  final autoAttachRaw = (results['auto-attach'] as String?) ??
      env['FLUTTER_NETWORK_MCP_AUTO_ATTACH'];
  final autoAttachAllowlist = _parseAllowlist(autoAttachRaw);
  if (autoAttachAllowlist.isNotEmpty) {
    AutoAttacher(
      defaultDtdUri: dtdUri,
      allowedAppPatterns: autoAttachAllowlist,
    ).start();
  }
}

/// Parses a comma-separated allowlist value into a list of trimmed, non-
/// empty patterns. Returns empty when [raw] is null, empty, or contains
/// only whitespace / empty segments.
List<String> _parseAllowlist(String? raw) {
  if (raw == null) return const [];
  final out = <String>[];
  for (final piece in raw.split(',')) {
    final trimmed = piece.trim();
    if (trimmed.isNotEmpty) out.add(trimmed);
  }
  return out;
}
