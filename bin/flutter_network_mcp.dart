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
    ..addFlag(
      'auto-attach',
      negatable: false,
      help:
          'Watch DTD for new apps and auto-attach as they appear. Apps '
          'already running at server startup are NOT auto-attached '
          '(seed-and-skip on first tick). Manual network_detach survives — '
          'detached apps stay in the known set, no re-attach. Poll '
          'interval: FLUTTER_NETWORK_MCP_AUTO_ATTACH_POLL_MS (default '
          '5000, clamped 1000–60000). Requires --dtd-uri or '
          'FLUTTER_NETWORK_MCP_DTD_URI. Env-var fallback: '
          'FLUTTER_NETWORK_MCP_AUTO_ATTACH=true|1.',
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
  // priority; env var (FLUTTER_NETWORK_MCP_AUTO_ATTACH=true|1) is the
  // fallback. No-op when no DTD URI is configured.
  final autoAttachEnv = env['FLUTTER_NETWORK_MCP_AUTO_ATTACH']?.toLowerCase();
  final autoAttach = (results['auto-attach'] as bool?) == true ||
      autoAttachEnv == 'true' ||
      autoAttachEnv == '1';
  if (autoAttach) {
    AutoAttacher(defaultDtdUri: dtdUri).start();
  }
}
