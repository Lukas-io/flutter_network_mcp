import 'dart:io' as io;

import 'package:dart_mcp/server.dart';
import 'package:dart_mcp/stdio.dart';

import 'config/capabilities.dart';
import 'version.dart';
import 'tools/alert_patterns.dart';
import 'tools/auto_attach_config_tool.dart';
import 'tools/alerts_clear.dart';
import 'tools/alerts_config.dart';
import 'tools/alerts_drain.dart';
import 'tools/alerts_peek.dart';
import 'tools/bodies_purge.dart';
import 'tools/db_stats.dart';
import 'tools/db_vacuum.dart';
import 'tools/ignored_hosts.dart';
import 'tools/logs_clear.dart';
import 'tools/logs_tail.dart';
import 'tools/network_attach.dart';
import 'tools/network_body.dart';
import 'tools/network_clear.dart';
import 'tools/network_correlate.dart';
import 'tools/network_detach.dart';
import 'tools/network_diff.dart';
import 'tools/network_discover_dtd.dart';
import 'tools/network_get.dart';
import 'tools/network_list.dart';
import 'tools/network_query.dart';
import 'tools/network_replay.dart';
import 'tools/network_search.dart';
import 'tools/network_status.dart';
import 'tools/network_summarize.dart';
import 'tools/report_issue.dart';
import 'tools/redacted_headers.dart';
import 'tools/session_close.dart';
import 'tools/session_delete.dart';
import 'tools/session_export.dart';
import 'tools/session_list.dart';
import 'tools/session_note.dart';
import 'tools/session_open.dart';
import 'tools/socket_clear.dart';
import 'tools/socket_get.dart';
import 'tools/socket_list.dart';

/// MCP server exposing Flutter DevTools data via DTD + VM service, with
/// persistent capture sessions in SQLite, full-text search, proactive alerts,
/// CLI-driven capability gating, and runtime configurability.
base class FlutterNetworkMcpServer extends MCPServer with ToolsSupport {
  FlutterNetworkMcpServer.fromStreamChannel(
    super.channel, {
    this.defaultDtdUri,
  }) : super.fromStreamChannel(
          implementation: Implementation(
            name: 'flutter_network_mcp',
            version: packageVersion,
          ),
          instructions:
              'Read HTTP, sockets, and logs from a running Flutter/Dart app, '
              'live or from history. network_status → alerts_drain → '
              'network_search / network_list / logs_tail. session_delete + '
              'db_vacuum keep the DB lean. See docs/tools for per-tool guides '
              'including when NOT to use each tool.\n\n'
              'FILING FEEDBACK (you, the agent, are the channel; use the '
              'report_issue tool). Proactively OFFER to file when ANY of these '
              'happens: (1) the user voices friction ("why did it not...", "I '
              'wish it...", "this is annoying"); (2) you hit a tool error or '
              'surprising output and have to work around it; (3) a non-trivial '
              'debugging session finishes, or the user signals done ("thanks", '
              '"moving on"). How to offer, one short line: "That '
              '[friction / workaround] would help the flutter_network_mcp '
              'maintainer. Want me to file a quick issue? I will draft it, you '
              'just approve." On yes, call report_issue (type:"bug" for wrong '
              'output / crashes / errors, type:"ux" for anything awkward, slow, '
              'or confusing); it submits via the gh CLI or returns a '
              'paste-ready body. Rules: ask before filing; at most once per '
              'conversation unless the user invites more; only file with a '
              'CONCRETE repro or a specific friction point, never a generic '
              '"it was great".',
        ) {
    final caps = CapabilityConfig.instance;

    // Lifecycle — always available.
    registerTool(networkStatusTool, (req) => networkStatus(req, defaultDtdUri));
    registerTool(networkAttachTool, (req) => networkAttach(req, defaultDtdUri));
    registerTool(networkDetachTool, networkDetach);
    registerTool(networkDiscoverDtdTool, networkDiscoverDtd);
    registerTool(reportIssueTool, reportIssue);
    registerTool(autoAttachConfigTool, autoAttachConfig);

    if (caps.isEnabled(Category.http)) {
      registerTool(networkListTool, networkList);
      registerTool(networkGetTool, networkGet);
      registerTool(networkBodyTool, networkBody);
      registerTool(networkClearTool, networkClear);
      registerTool(networkDiffTool, networkDiff);
      registerTool(networkReplayTool, networkReplay);
      registerTool(networkSummarizeTool, networkSummarize);
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
      registerTool(alertsClearTool, alertsClear);
      registerTool(alertPatternsTool, alertPatterns);
    }

    if (caps.isEnabled(Category.search)) {
      registerTool(networkSearchTool, networkSearch);
      registerTool(networkCorrelateTool, networkCorrelate);
    }

    if (caps.isEnabled(Category.sessions)) {
      registerTool(sessionListTool, sessionList);
      registerTool(sessionOpenTool, sessionOpen);
      registerTool(sessionCloseTool, sessionClose);
      registerTool(sessionExportTool, sessionExport);
      registerTool(sessionNoteTool, sessionNote);
      registerTool(sessionDeleteTool, sessionDelete);
    }

    if (caps.isEnabled(Category.sql)) {
      registerTool(networkQueryTool, networkQuery);
    }

    if (caps.isEnabled(Category.admin)) {
      registerTool(ignoredHostsTool, ignoredHosts);
      registerTool(redactedHeadersTool, redactedHeaders);
      registerTool(dbStatsTool, dbStats);
      registerTool(dbVacuumTool, dbVacuum);
      registerTool(bodiesPurgeTool, bodiesPurge);
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
