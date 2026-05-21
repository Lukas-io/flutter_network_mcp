import 'dart:io' as io;

import 'package:args/args.dart';
import 'package:flutter_network_mcp/src/config/capabilities.dart';
import 'package:flutter_network_mcp/src/server.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';

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
          'Directory for captures.db. Defaults to '
          r'$XDG_DATA_HOME/flutter_network_mcp or ~/.local/share/flutter_network_mcp.',
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

  CapturesDatabase.open(dataDir: dataDir);

  FlutterNetworkMcpServer.stdio(defaultDtdUri: dtdUri);
}
