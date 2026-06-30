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
import 'tools/capture_allow.dart';
import 'tools/ignored_hosts.dart';
import 'tools/logs_clear.dart';
import 'tools/logs_tail.dart';
import 'tools/network_attach.dart';
import 'tools/network_body.dart';
import 'tools/network_body_outline.dart';
import 'tools/network_body_query.dart';
import 'tools/network_clear.dart';
import 'tools/network_correlate.dart';
import 'tools/network_detach.dart';
import 'tools/network_diff.dart';
import 'tools/network_discover_dtd.dart';
import 'tools/network_get.dart';
import 'tools/network_list.dart';
import 'tools/network_query.dart';
import 'tools/network_replay.dart';
import 'tools/network_replay_as_test.dart';
import 'tools/network_search.dart';
import 'tools/network_status.dart';
import 'tools/network_diff_session.dart';
import 'tools/network_drift.dart';
import 'tools/network_report.dart';
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
              'live or from history. Start with network_status; it reports '
              'what is reachable and its nextSteps tell you what to call next. '
              'See docs/tools for per-tool guides.\n\n'
              'You are the maintainer feedback channel. When the user voices '
              'friction, you hit a surprising tool error you have to work '
              'around, or a debugging session wraps up, OFFER (at most once '
              'per conversation, only with a concrete repro) to file via '
              'report_issue. One line: "Want me to file a quick issue for the '
              'maintainer? I will draft it, you approve." Use type:"bug" for '
              'wrong output or crashes, "ux" for anything awkward or confusing.',
        ) {
    final caps = CapabilityConfig.instance;

    _register(networkStatusTool, (req) => networkStatus(req, defaultDtdUri));
    _register(networkAttachTool, (req) => networkAttach(req, defaultDtdUri));
    _register(networkDetachTool, networkDetach);
    _register(networkDiscoverDtdTool, networkDiscoverDtd);
    _register(reportIssueTool, reportIssue);
    _register(autoAttachConfigTool, autoAttachConfig);
    _register(sessionConfigureTool, sessionConfigure);
    _register(usageStatsTool, usageStats);

    if (caps.isEnabled(Category.http)) {
      _register(networkListTool, networkList);
      _register(networkGetTool, networkGet);
      _register(networkBodyTool, networkBody);
      _register(networkBodyOutlineTool, networkBodyOutline);
      _register(networkBodyQueryTool, networkBodyQuery);
      _register(networkClearTool, networkClear);
      _register(networkDiffTool, networkDiff);
      _register(networkReplayTool, networkReplay);
      _register(networkReplayAsTestTool, networkReplayAsTest);
      _register(networkSummarizeTool, networkSummarize);
      _register(networkDiffSessionTool, networkDiffSession);
      _register(networkDriftTool, networkDrift);
      _register(networkReportTool, networkReport);
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
      _register(captureAllowTool, captureAllow);
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
