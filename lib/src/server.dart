import 'dart:io' as io;

import 'package:dart_mcp/server.dart';
import 'package:dart_mcp/stdio.dart';

import 'config/capabilities.dart';
import 'tools/alerts_config.dart';
import 'tools/alerts_drain.dart';
import 'tools/alerts_peek.dart';
import 'tools/ignored_hosts.dart';
import 'tools/logs_clear.dart';
import 'tools/logs_tail.dart';
import 'tools/network_attach.dart';
import 'tools/network_body.dart';
import 'tools/network_clear.dart';
import 'tools/network_detach.dart';
import 'tools/network_diff.dart';
import 'tools/network_get.dart';
import 'tools/network_list.dart';
import 'tools/network_query.dart';
import 'tools/network_replay.dart';
import 'tools/network_search.dart';
import 'tools/network_status.dart';
import 'tools/session_close.dart';
import 'tools/session_export.dart';
import 'tools/session_list.dart';
import 'tools/session_note.dart';
import 'tools/session_open.dart';
import 'tools/socket_clear.dart';
import 'tools/socket_get.dart';
import 'tools/socket_list.dart';

/// MCP server exposing Flutter DevTools data via DTD + VM service, with
/// persistent capture sessions in SQLite, full-text search, proactive alerts,
/// and CLI-driven capability gating.
base class FlutterNetworkMcpServer extends MCPServer with ToolsSupport {
  FlutterNetworkMcpServer.fromStreamChannel(
    super.channel, {
    this.defaultDtdUri,
  }) : super.fromStreamChannel(
          implementation: Implementation(
            name: 'flutter_network_mcp',
            version: '0.4.0',
          ),
          instructions:
              'Read HTTP traffic, socket stats, and app logs from a running '
              'Flutter/Dart app, live or from history. Start with '
              'network_status to see capabilities and pending alerts. '
              'network_attach opens a capture session; tools auto-persist. '
              'alerts_drain at the top of an investigation surfaces issues '
              'the server detected without you having to ask. See docs/tools '
              'for per-tool guidance including when NOT to use each tool.',
        ) {
    final caps = CapabilityConfig.instance;

    // Lifecycle — always available.
    registerTool(networkStatusTool, (req) => networkStatus(req, defaultDtdUri));
    registerTool(networkAttachTool, (req) => networkAttach(req, defaultDtdUri));
    registerTool(networkDetachTool, networkDetach);

    if (caps.isEnabled(Category.http)) {
      registerTool(networkListTool, networkList);
      registerTool(networkGetTool, networkGet);
      registerTool(networkBodyTool, networkBody);
      registerTool(networkClearTool, networkClear);
      registerTool(networkDiffTool, networkDiff);
      registerTool(networkReplayTool, networkReplay);
    }

    if (caps.isEnabled(Category.sockets)) {
      registerTool(socketListTool, socketList);
      registerTool(socketGetTool, socketGet);
      registerTool(socketClearTool, socketClear);
    }

    if (caps.isEnabled(Category.logs)) {
      registerTool(logsTailTool, logsTail);
      registerTool(logsClearTool, logsClear);
    }

    if (caps.isEnabled(Category.alerts)) {
      registerTool(alertsDrainTool, alertsDrain);
      registerTool(alertsPeekTool, alertsPeek);
      registerTool(alertsConfigTool, alertsConfig);
    }

    if (caps.isEnabled(Category.search)) {
      registerTool(networkSearchTool, networkSearch);
    }

    if (caps.isEnabled(Category.sessions)) {
      registerTool(sessionListTool, sessionList);
      registerTool(sessionOpenTool, sessionOpen);
      registerTool(sessionCloseTool, sessionClose);
      registerTool(sessionExportTool, sessionExport);
      registerTool(sessionNoteTool, sessionNote);
    }

    if (caps.isEnabled(Category.sql)) {
      registerTool(networkQueryTool, networkQuery);
    }

    if (caps.isEnabled(Category.admin)) {
      registerTool(ignoredHostsTool, ignoredHosts);
    }
  }

  final String? defaultDtdUri;

  factory FlutterNetworkMcpServer.stdio({String? defaultDtdUri}) {
    return FlutterNetworkMcpServer.fromStreamChannel(
      stdioChannel(input: io.stdin, output: io.stdout),
      defaultDtdUri: defaultDtdUri,
    );
  }
}
