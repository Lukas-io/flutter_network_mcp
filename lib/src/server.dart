import 'dart:async';
import 'dart:io' as io;

import 'package:dart_mcp/server.dart';
import 'package:dart_mcp/stdio.dart';

import 'config/capabilities.dart';
import 'telemetry/usage_recorder.dart';
import 'version.dart';
import 'tools/alert_patterns.dart';
import 'tools/auto_attach_config_tool.dart';
import 'tools/alerts_clear.dart';
import 'tools/alerts_config.dart';
import 'tools/alerts_drain.dart';
import 'tools/alerts_peek.dart';
import 'tools/bodies_purge.dart';
import 'tools/correlate_at.dart';
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
import 'tools/session_configure.dart';
import 'tools/session_delete.dart';
import 'tools/session_export.dart';
import 'tools/session_list.dart';
import 'tools/session_note.dart';
import 'tools/session_open.dart';
import 'tools/socket_clear.dart';
import 'tools/socket_get.dart';
import 'tools/socket_list.dart';
import 'tools/usage_stats.dart';

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
    _register(networkStatusTool, (req) => networkStatus(req, defaultDtdUri));
    _register(networkAttachTool, (req) => networkAttach(req, defaultDtdUri));
    _register(networkDetachTool, networkDetach);
    _register(networkDiscoverDtdTool, networkDiscoverDtd);
    _register(reportIssueTool, reportIssue);
    _register(autoAttachConfigTool, autoAttachConfig);
    // Sticky default filters tune whatever read tools are enabled (#18).
    _register(sessionConfigureTool, sessionConfigure);
    // Usage analytics is process-wide + always available (#79 Phase 2).
    _register(usageStatsTool, usageStats);

    if (caps.isEnabled(Category.http)) {
      _register(networkListTool, networkList);
      _register(networkGetTool, networkGet);
      _register(networkBodyTool, networkBody);
      _register(networkClearTool, networkClear);
      _register(networkDiffTool, networkDiff);
      _register(networkReplayTool, networkReplay);
      _register(networkSummarizeTool, networkSummarize);
    }

    if (caps.isEnabled(Category.sockets)) {
      _register(socketListTool, socketList);
      _register(socketGetTool, socketGet);
      _register(socketClearTool, socketClear);
    }

    if (caps.isEnabled(Category.logs)) {
      _register(logsTailTool, logsTail);
      _register(logsClearTool, logsClear);
    }

    // #18: log<->network correlation bridges the http + logs surfaces, so it
    // is available whenever either side is on (it returns only the enabled
    // sides).
    if (caps.isEnabled(Category.http) || caps.isEnabled(Category.logs)) {
      _register(correlateAtTool, correlateAt);
    }

    if (caps.isEnabled(Category.alerts)) {
      _register(alertsDrainTool, alertsDrain);
      _register(alertsPeekTool, alertsPeek);
      _register(alertsConfigTool, alertsConfig);
      _register(alertsClearTool, alertsClear);
      _register(alertPatternsTool, alertPatterns);
    }

    if (caps.isEnabled(Category.search)) {
      _register(networkSearchTool, networkSearch);
      _register(networkCorrelateTool, networkCorrelate);
    }

    if (caps.isEnabled(Category.sessions)) {
      _register(sessionListTool, sessionList);
      _register(sessionOpenTool, sessionOpen);
      _register(sessionCloseTool, sessionClose);
      _register(sessionExportTool, sessionExport);
      _register(sessionNoteTool, sessionNote);
      _register(sessionDeleteTool, sessionDelete);
    }

    if (caps.isEnabled(Category.sql)) {
      _register(networkQueryTool, networkQuery);
    }

    if (caps.isEnabled(Category.admin)) {
      _register(ignoredHostsTool, ignoredHosts);
      _register(redactedHeadersTool, redactedHeaders);
      _register(dbStatsTool, dbStats);
      _register(dbVacuumTool, dbVacuum);
      _register(bodiesPurgeTool, bodiesPurge);
    }
  }

  /// Registers [tool] and instruments it: every call records a privacy-safe
  /// usage event (issue #79). The recorder swallows its own errors, so this
  /// wrapper never changes a tool's behaviour or failure mode.
  void _register(
    Tool tool,
    FutureOr<CallToolResult> Function(CallToolRequest) handler,
  ) {
    registerTool(tool, (req) async {
      final sw = Stopwatch()..start();
      try {
        final result = await handler(req);
        UsageRecorder.instance.record(
          tool: tool.name,
          request: req,
          durationMs: sw.elapsedMilliseconds,
          result: result,
        );
        return result;
      } catch (_) {
        UsageRecorder.instance.record(
          tool: tool.name,
          request: req,
          durationMs: sw.elapsedMilliseconds,
          result: null,
        );
        rethrow;
      }
    });
  }

  final String? defaultDtdUri;

  factory FlutterNetworkMcpServer.stdio({String? defaultDtdUri}) {
    return FlutterNetworkMcpServer.fromStreamChannel(
      stdioChannel(input: io.stdin, output: io.stdout),
      defaultDtdUri: defaultDtdUri,
    );
  }
}
