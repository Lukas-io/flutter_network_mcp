import 'dart:async';
import 'dart:io' as io;

import 'package:dart_mcp/server.dart';
import 'package:dart_mcp/stdio.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

import 'config/capabilities.dart';
import 'docs/doc_resources.dart';
import 'tools/network_wait_for_app.dart';
import 'telemetry/usage_recorder.dart';
import 'version.dart';
import 'tools/alert_patterns.dart';
import 'tools/result.dart';
import 'tools/error_kind.dart';
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
import 'tools/ws_get.dart';
import 'tools/ws_list.dart';
import 'util/network_env.dart';
import 'util/legacy_install.dart';

/// A notice the agent passes to the user while this install still uses the flutter_network_mcp names.
String _legacyInstructions() {
  final notice = legacyUse.notice;
  return notice == null ? '' : 'TELL THE USER, once and early: $notice\n\n';
}

/// MCP server exposing Flutter DevTools data via DTD + VM service, with
/// persistent capture sessions in SQLite, full-text search, proactive alerts,
/// CLI-driven capability gating, and runtime configurability.
base class FlutterNetworkMcpServer extends MCPServer
    with ToolsSupport, ResourcesSupport {
  FlutterNetworkMcpServer.fromStreamChannel(
    super.channel, {
    this.defaultDtdUri,
  }) : super.fromStreamChannel(
          implementation: Implementation(
            name: 'glint_network',
            version: packageVersion,
          ),
          instructions: '${_legacyInstructions()}'
              'Read HTTP, sockets, and logs from a running Flutter/Dart app, '
              'live or from history. Start with network_status; it reports '
              'what is reachable and its nextSteps tell you what to call next. '
              'Per-tool guides and the response contract are available as MCP '
              'resources (glint-network://docs/...) — read them for deep '
              'usage. Only dart:io HTTP is captured: native SDK traffic '
              '(analytics, crash reporting, ads, maps) is invisible here, so '
              'never conclude an SDK is idle from an empty capture.\n\n'
              'When the user voices friction with these tools, or you hit a '
              'surprising tool error you have to work around, you may OFFER '
              '(at most once per conversation, only with a concrete repro) to '
              'file it via report_issue: "Want me to draft an issue for the '
              'maintainer? You approve before anything is posted." Draft with '
              'auto:false, show it, and file only after the user agrees. Use '
              'type:"bug" for wrong output or crashes, "ux" for anything '
              'awkward or confusing.',
        ) {
    final caps = CapabilityConfig.instance;

    _register(networkStatusTool, (req) => networkStatus(req, defaultDtdUri));
    _register(
        networkWaitForAppTool,
        (req) => networkWaitForApp(req, defaultDtdUri,
            notifyProgress: notifyProgress));
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

    if (caps.isEnabled(Category.websockets)) {
      _register(wsListTool, wsList);
      _register(wsGetTool, wsGet);
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

    _registerDocResources();
  }

  /// D6 (audit RC10/F8): expose the shipped `docs/**` guides as MCP
  /// resources so a fresh agent (with no repo checkout) can actually read
  /// the per-tool guides and the response contract the tool descriptions
  /// point at. Best-effort — a missing docs dir just yields no resources.
  void _registerDocResources() {
    try {
      for (final doc in DocResources.discover()) {
        addResource(
          Resource(
            uri: doc.uri,
            name: doc.name,
            mimeType: 'text/markdown',
            description: 'glint_network guide: ${doc.name}',
          ),
          (req) async {
            final text = await io.File(doc.path).readAsString();
            return ReadResourceResult(contents: [
              TextResourceContents(
                uri: doc.uri,
                text: text,
                mimeType: 'text/markdown',
              ),
            ]);
          },
        );
      }
    } catch (_) {/* docs unavailable — tools still work */}
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
        final result = await boundedToolCall(tool.name, () => handler(req));
        final ms = sw.elapsedMilliseconds;
        if (ms >= kSlowToolMs) {
          io.stderr.writeln('glint_network: ${tool.name} took ${ms}ms');
        }
        UsageRecorder.instance.record(
          tool: tool.name,
          request: req,
          durationMs: ms,
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

/// Calls slower than this are logged to stderr so a hang has a trail.
const int kSlowToolMs = 2000;

/// Tools that legitimately run long (compaction, export, replay).
const Set<String> kUnboundedTools = {
  'db_vacuum',
  'session_export',
  'network_replay',
  'network_replay_as_test',
  'report_issue',
  'bodies_purge',
  'network_wait_for_app',
};

/// `GLINT_NETWORK_TOOL_TIMEOUT_MS` (2000–120000). Default 20000.
Duration toolDeadline() {
  final raw = networkEnv['GLINT_NETWORK_TOOL_TIMEOUT_MS'];
  final parsed = raw == null ? null : int.tryParse(raw);
  if (parsed == null) return const Duration(seconds: 20);
  return Duration(milliseconds: parsed.clamp(2000, 120000));
}

/// Runs [body] under the per-tool deadline. A call that overruns comes back
/// as errorKind `timeout` (the work keeps running in the background, its
/// result discarded); a database locked past busy_timeout comes back as
/// `unresponsive_db`. Neither ever hangs the MCP host.
Future<CallToolResult> boundedToolCall(
  String tool,
  FutureOr<CallToolResult> Function() body, {
  Duration? deadline,
}) async {
  final limit = deadline ?? toolDeadline();
  try {
    if (kUnboundedTools.contains(tool)) return await body();
    return await Future<CallToolResult>.sync(body).timeout(limit);
  } on TimeoutException {
    io.stderr.writeln(
      'glint_network: $tool exceeded ${limit.inMilliseconds}ms and was '
      'cut off; the work continues in the background.',
    );
    return errorResult(
      '$tool did not finish within ${limit.inSeconds}s.',
      kind: ErrorKind.timeout,
      extra: {
        'timeoutMs': limit.inMilliseconds,
        'nextSteps': const [
          'Retry with a narrower filter or a smaller limit',
          'network_status — check whether the session is still reachable',
          'Raise GLINT_NETWORK_TOOL_TIMEOUT_MS if this tool legitimately needs longer',
        ],
      },
    );
  } on sql.SqliteException catch (e) {
    if (e.resultCode == 5 || e.resultCode == 6) {
      return errorResult(
        'captures.db is locked by another process (${e.message}).',
        kind: ErrorKind.unresponsiveDb,
        extra: const {
          'nextSteps': [
            'Another glint_network server (another IDE window?) holds the database; close it or start this one with --data-dir <other>',
            'Retry in a few seconds',
          ],
        },
      );
    }
    rethrow;
  }
}
