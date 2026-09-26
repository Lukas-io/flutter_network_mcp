import 'dart:async' show runZonedGuarded, unawaited;
import 'dart:io' as io;

import 'package:args/args.dart';
import 'package:flutter_network_mcp/src/auto_attach.dart';
import 'package:flutter_network_mcp/src/config/auto_attach_config.dart';
import 'package:flutter_network_mcp/src/config/capabilities.dart';
import 'package:flutter_network_mcp/src/install/install.dart';
import 'package:flutter_network_mcp/src/install/setup.dart';
import 'package:flutter_network_mcp/src/install/update.dart';
import 'package:flutter_network_mcp/src/server.dart';
import 'package:flutter_network_mcp/src/session_migrator.dart';
import 'package:flutter_network_mcp/src/alerts/alert_retention.dart';
import 'package:flutter_network_mcp/src/state/session.dart';
import 'package:flutter_network_mcp/src/storage/captures_db.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:flutter_network_mcp/src/telemetry/audit_subcommand.dart';
import 'package:flutter_network_mcp/src/telemetry/usage_reporter.dart';
import 'package:flutter_network_mcp/src/telemetry/usage_subcommand.dart';
import 'package:flutter_network_mcp/src/telemetry/telemetry_reporter.dart';
import 'package:flutter_network_mcp/src/tools/alert_patterns.dart' as alert_patterns;
import 'package:flutter_network_mcp/src/update/update_check.dart';
import 'package:flutter_network_mcp/src/version.dart';
import 'package:flutter_network_mcp/src/vm/dtd_discovery.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_network_mcp/src/util/network_env.dart';
import 'package:flutter_network_mcp/src/util/legacy_install.dart';

Future<void> main(List<String> args) async {
  // Top-level zone guard. Anything that escapes the per-call try/catches
  // inside the server, capture writer, gateways, etc. lands here — we log
  // it cleanly to stderr (so the MCP host sees a closed channel, not a
  // raw Dart trace) and set exit code 70 (EX_SOFTWARE).
  //
  // 0.7.1: the handler also fires TelemetryReporter.maybeReport, which
  // writes a tamper-evident audit log + (when configured) POSTs an
  // anonymized payload to the maintainer's collector, only for users who
  // set GLINT_NETWORK_TELEMETRY=on. See
  // docs/telemetry.md.
  await runZonedGuarded(() => _runMain(args), (error, stack) {
    io.stderr.writeln(
      'glint_network: UNCAUGHT ERROR ($error). The MCP host will see '
      'the stdio channel close — restart your MCP host to recover. Please '
      'report this at https://github.com/Lukas-io/glint/issues '
      'with the trace below.\n$stack',
    );
    unawaited(
      TelemetryReporter.maybeReport(error: error, stack: stack),
    );
    io.exitCode = 70;
  });
}

Future<void> _runMain(List<String> args) async {
  final legacyNotice = legacyUse.notice;
  if (legacyNotice != null) io.stderr.writeln('glint_network: $legacyNotice');
  // Subcommands short-circuit ArgParser. Keep this dispatch FIRST so a
  // typo on the main flags doesn't pre-empt `install` / `update`.
  if (args.isNotEmpty) {
    switch (args.first) {
      case 'install':
        return runInstall(args.skip(1).toList());
      case 'update':
        return runUpdate(args.skip(1).toList());
      case 'audit':
        return runAudit(args.skip(1).toList());
      case 'usage':
        return runUsage(args.skip(1).toList());
      case 'setup':
        return runSetup(args.skip(1).toList());
    }
  }

  // JIT-mode startup nudge. The standard `dart pub global activate -s git`
  // install ships a snapshot wrapper that recompiles on every spawn (~1–2s
  // cold), which the MCP host can race and mark the server "Failed to
  // connect". `bool.fromEnvironment('dart.vm.product')` is the canonical
  // AOT-vs-JIT check — true only when compiled with `dart compile exe`.
  final envForNudge = networkEnv;
  if (!isAotBuild &&
      envForNudge['GLINT_NETWORK_NO_JIT_NUDGE']?.toLowerCase() != 'true') {
    io.stderr.writeln(
      'glint_network: running in JIT mode — slow cold-start may '
      'cause MCP host handshake timeouts ("Failed to connect" on first '
      'attach, then success on the next probe). Run '
      '`glint_network install` once for sub-100ms native startup. '
      '(Set GLINT_NETWORK_NO_JIT_NUDGE=true to silence.)',
    );
  }

  final parser = ArgParser()
    ..addOption(
      'dtd-uri',
      help:
          'Default DTD WebSocket URI for network_attach. Falls back to the '
          'GLINT_NETWORK_DTD_URI environment variable. When neither '
          'is set the server auto-discovers from the standard package:dtd '
          'discovery dir (~/Library/Application Support/dart/dtd on macOS) '
          'unless --no-auto-discover-dtd is passed.',
    )
    ..addFlag(
      'no-auto-discover-dtd',
      negatable: false,
      help:
          'Disable auto-discovery of DTD from the standard package:dtd '
          'discovery directory at startup. Use when you want a fully '
          'explicit .mcp.json (paranoid configs, CI, multi-DTD machines '
          'where guessing would be dangerous). Env-var fallback: '
          'GLINT_NETWORK_AUTO_DISCOVER_DTD=false.',
    )
    ..addOption(
      'data-dir',
      help:
          'Directory for captures.db. macOS default: '
          '~/Library/Application Support/flutter_network_mcp. '
          r'Linux default: $XDG_DATA_HOME/flutter_network_mcp or '
          '~/.local/share/flutter_network_mcp. Env-var fallback: '
          'GLINT_NETWORK_DATA_DIR.',
    )
    ..addFlag(
      'no-persist',
      negatable: false,
      help:
          'Ephemeral mode: keep captures in memory only, never write to disk. '
          'Captures are readable live but vanish when the server exits. For '
          'noisy or sensitive flows. Env-var fallback: '
          'GLINT_NETWORK_NO_PERSIST=true.',
    )
    ..addOption(
      'capabilities',
      help:
          'Comma-separated allowlist of categories to enable. Options: '
          'http, sockets, websockets, logs, alerts, search, sessions, sql, '
          'admin. '
          'Lifecycle (status/attach/detach) is always on. Falls back to '
          'GLINT_NETWORK_CAPABILITIES. Mutually exclusive with --disable.',
    )
    ..addOption(
      'disable',
      help:
          'Comma-separated denylist of categories to disable. Same option '
          'set as --capabilities. Falls back to GLINT_NETWORK_DISABLE.',
    )
    ..addOption(
      'auto-attach',
      help:
          'Watch DTD for new apps and auto-attach them. Value is a '
          'comma-separated allowlist of case-insensitive substring '
          'patterns matched against the app name from DTD; only matching '
          'apps are auto-attached. Example: '
          '--auto-attach=eats_mobile,eats_driver. There is NO bool '
          'form — to enable auto-attach you MUST specify which apps. '
          'Absent or empty value disables. Apps already running at '
          'startup that match the allowlist ARE auto-attached on the '
          'first tick (0.6.2 change — the allowlist is the explicit '
          'opt-in). Manual network_detach survives — detached apps '
          'stay in the known set so they won\'t re-attach. '
          'Poll interval: GLINT_NETWORK_AUTO_ATTACH_POLL_MS '
          '(default 5000, clamped 1000–60000). Requires --dtd-uri or '
          'GLINT_NETWORK_DTD_URI. Env-var fallback: '
          'GLINT_NETWORK_AUTO_ATTACH=app1,app2.',
    )
    ..addOption(
      'auto-attach-deny',
      help:
          'Optional denylist for auto-attach. Comma-separated case-'
          'insensitive substring patterns matched against the app name '
          'from DTD; matching apps are skipped even if they also match '
          '--auto-attach. Useful for excluding specific devices like '
          'physical hardware or emulators when the allowlist would '
          'otherwise grab them. Example: '
          '--auto-attach=eats_mobile --auto-attach-deny="Pixel 7,Android emulator". '
          'Env-var fallback: GLINT_NETWORK_AUTO_ATTACH_DENY=pat1,pat2.',
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
    io.stderr.writeln('glint_network');
    io.stderr.writeln(parser.usage);
    return;
  }

  final env = networkEnv;
  var dtdUri = (results['dtd-uri'] as String?) ??
      env['GLINT_NETWORK_DTD_URI'];

  // Auto-discover the DTD URI from the standard package:dtd discovery dir
  // when nothing was configured explicitly. Opt-out: --no-auto-discover-dtd
  // or GLINT_NETWORK_AUTO_DISCOVER_DTD=false. When discovery finds
  // nothing, dtdUri stays null and downstream behaviour is unchanged
  // (network_attach reports its existing "no DTD URI configured" error).
  final autoDiscover = !((results['no-auto-discover-dtd'] as bool?) ?? false) &&
      (env['GLINT_NETWORK_AUTO_DISCOVER_DTD']?.toLowerCase() != 'false');
  if (dtdUri == null && autoDiscover) {
    final candidates = DtdDiscovery.discover();
    final picked = candidates.isEmpty ? null : candidates.first;
    if (picked != null) {
      dtdUri = picked.wsUri;
      io.stderr.writeln(
        'glint_network: auto-discovered DTD at $dtdUri '
        '(pid ${picked.pid}, '
        'workspaceRoot: ${picked.workspaceRoot ?? "(unknown)"}, '
        'epoch ${picked.epoch.toIso8601String()}). '
        'Pass --dtd-uri to override or --no-auto-discover-dtd to disable.',
      );
    }
  }

  final dataDir = results['data-dir'] as String?;
  final capabilities =
      (results['capabilities'] as String?) ?? env['GLINT_NETWORK_CAPABILITIES'];
  final disable = (results['disable'] as String?) ?? env['GLINT_NETWORK_DISABLE'];

  try {
    CapabilityConfig.install(
      CapabilityConfig.fromFlags(allowlist: capabilities, denylist: disable),
    );
  } on ArgumentError catch (e) {
    io.stderr.writeln('Error: ${e.message}');
    io.exitCode = 64;
    return;
  }

  final noPersist = (results['no-persist'] as bool? ?? false) ||
      env['GLINT_NETWORK_NO_PERSIST']?.toLowerCase() == 'true';

  try {
    CapturesDatabase.open(dataDir: dataDir, inMemory: noPersist);
  } on io.FileSystemException catch (e) {
    io.stderr.writeln(
      'glint_network: cannot create data dir '
      '(${e.osError?.message ?? e.message}).\n'
      'Pass --data-dir <writable path> or set GLINT_NETWORK_DATA_DIR.',
    );
    io.exitCode = 73; // EX_CANTCREAT
    return;
  } on NewerDatabaseError catch (e) {
    io.stderr.writeln('glint_network: $e');
    io.exitCode = 78; // EX_CONFIG
    return;
  } on StateError catch (e) {
    // Thrown by CapturesDatabase.open() when every candidate failed.
    io.stderr.writeln('glint_network: ${e.message}');
    io.exitCode = 73;
    return;
  } catch (e, st) {
    // Defense-in-depth: schema migration failures throw SqliteException;
    // sqlite3 native errors throw their own types; corrupt DB throws on
    // first PRAGMA. Whatever the source, surface a clean error + exit
    // code 70 (EX_SOFTWARE) instead of crashing with a raw Dart stack.
    io.stderr.writeln(
      'glint_network: database open failed ($e). The DB may be '
      'corrupted or running a migration this binary version doesn\'t '
      'support. Try --data-dir <fresh path> to bypass.',
    );
    io.stderr.writeln(st);
    io.exitCode = 70;
    return;
  }

  // Hydrate user-defined alert patterns from the DB so they fire from the
  // very first capture tick.
  try {
    alert_patterns.loadCustomPatternsFromDb();
  } catch (_) {/* table may be empty / freshly migrated */}
  if (!noPersist) {
    try {
      final orphaned = CapturesDao().endOrphanedSessions();
      if (orphaned > 0) {
        io.stderr.writeln(
          'glint_network: ended $orphaned session(s) left open by an '
          'earlier process; their captures stay readable as history.',
        );
      }
    } catch (e) {
      io.stderr.writeln('glint_network: orphan sweep failed: $e');
    }
  }

  // RC2 repair pass: index any historical requests missing from the FTS
  // map (the old writer only indexed inside the body-backfill's has-body
  // branch, so in-flight-at-first-sight and empty-body requests were never
  // searchable). One-shot, idempotent, deferred so it can never slow the
  // MCP handshake.
  if (!noPersist) {
    unawaited(Future<void>.delayed(const Duration(seconds: 5), () {
      try {
        final repaired = CapturesDao().repairSearchIndex();
        if (repaired > 0) {
          io.stderr.writeln(
            'glint_network: search-index repair added $repaired '
            'previously-unindexed request(s).',
          );
        }
      } catch (e) {
        io.stderr.writeln('glint_network: search-index repair failed: $e');
      }
    }));
  }

  final server = FlutterNetworkMcpServer.stdio(defaultDtdUri: dtdUri);
  _installLifecycleGuard(server);
  SessionRegistry.instance.startHeartbeat();

  // Background "is there a newer version?" probe. Daily-cached, opt-out
  // via GLINT_NETWORK_NO_UPDATE_CHECK=true. Fire-and-forget — never
  // blocks the MCP-host JSON-RPC handshake, never disturbs startup.
  unawaited(
    UpdateCheck.maybeCheck(
      currentVersion: packageVersion,
      dataDir: p.dirname(CapturesDatabase.instance.path),
    ),
  );

  // Background usage-rollup ship (#79 Phase 3). Daily-gated and opt-in
  // (GLINT_NETWORK_TELEMETRY=on). Folds the events accrued
  // since the last ship into one privacy-safe aggregate, records it to the
  // tamper-evident audit log, and POSTs to the collector when configured.
  // Fire-and-forget: never blocks the MCP-host handshake, never throws.
  unawaited(UsageReporter.maybeAutoShip());

  // Optional: watch DTD for new apps and auto-attach. CLI flag takes
  // priority; env var fallback is GLINT_NETWORK_AUTO_ATTACH=app1,app2.
  // Value is a comma-separated allowlist of substring patterns. Empty /
  // absent disables. No bool form — to enable auto-attach you must say
  // which apps it's allowed to grab.
  // 0.7.4: resolution order is file → env var → CLI flag, each step
  // overriding the previous. The file is the persistent default the user
  // sets via the agent-callable `auto_attach_config` tool; env vars and
  // flags are per-launch overrides.
  final fileConfig = AutoAttachConfig.loadFromFile();
  final envAllowRaw = env['GLINT_NETWORK_AUTO_ATTACH'];
  final flagAllowRaw = results['auto-attach'] as String?;
  final autoAttachAllowlist = flagAllowRaw != null
      ? _parseAllowlist(flagAllowRaw)
      : envAllowRaw != null
          ? _parseAllowlist(envAllowRaw)
          : fileConfig.allowed;
  final envDenyRaw = env['GLINT_NETWORK_AUTO_ATTACH_DENY'];
  final flagDenyRaw = results['auto-attach-deny'] as String?;
  final autoAttachDenylist = flagDenyRaw != null
      ? _parseAllowlist(flagDenyRaw)
      : envDenyRaw != null
          ? _parseAllowlist(envDenyRaw)
          : fileConfig.denied;

  // Publish the resolved config so non-bin/ tools (network_attach's
  // autoAttachSuggestion hint) can read it without re-parsing.
  AutoAttachConfig.set(
    allowed: autoAttachAllowlist,
    denied: autoAttachDenylist,
    logBufferSize: fileConfig.logBufferSize,
    nativeLogs: fileConfig.nativeLogs,
  );

  if (autoAttachAllowlist.isNotEmpty) {
    AutoAttacher(
      defaultDtdUri: dtdUri,
      allowedAppPatterns: autoAttachAllowlist,
      deniedAppPatterns: autoAttachDenylist,
    ).start();
  }

  // #16: hot-restart auto-migration watcher. Keeps a session id stable when
  // an attached app's VM URI changes across a restart, for ANY attached app
  // (not just auto-attached ones). Cheap when nothing is attached (the tick
  // early-returns). Opt out with GLINT_NETWORK_NO_AUTO_MIGRATE=true.
  if (env['GLINT_NETWORK_NO_AUTO_MIGRATE']?.toLowerCase() != 'true') {
    SessionMigrator(defaultDtdUri: dtdUri).start();
  }

  // Alert retention: auto-expire old alerts from non-attached sessions so
  // the pending banner reflects recent state instead of accumulating for
  // weeks. Window via GLINT_NETWORK_ALERT_RETENTION_DAYS (default 14,
  // 0 = keep forever); runtime-tunable via alerts_config. Runs a deferred
  // first sweep + hourly, independent of attach.
  if (!noPersist) {
    AlertRetention().start();
  }
}

/// 0.9.17: exit when the MCP host goes away, instead of living forever.
///
/// The VM stays alive on its own after the stdio channel dies: the
/// auto-attach / session-migrator timers, the sqlite handle, and any DTD /
/// VM-service WebSockets all hold the event loop open. Before this guard,
/// killing or reconnecting the MCP host (a `/mcp` reconnect, a crashed IDE,
/// a closed terminal) orphaned the server — observed in the wild as
/// multi-day `glint_network` processes re-parented to PID 1. The pub
/// `sh` shim compounds it: it neither execs nor forwards signals, so a
/// SIGTERM aimed at the wrapper never reaches the Dart VM.
///
/// Two triggers, one exit path:
///  - [MCPServer.done]: dart_mcp completes it when the stdio channel closes
///    (host exited or reconnected → stdin EOF). The reliable signal.
///  - SIGTERM / SIGINT: direct kills of the VM process itself.
///
/// The WAL checkpoint via [CapturesDatabase.close] is best-effort;
/// [io.exit] is the point — lingering timers and sockets do not get a vote.
void _installLifecycleGuard(FlutterNetworkMcpServer server) {
  var exiting = false;
  Never shutdown(String reason) {
    if (!exiting) {
      exiting = true;
      io.stderr.writeln('glint_network: $reason — shutting down.');
      try {
        CapturesDatabase.instance.close();
      } catch (_) {/* already closed or never opened */}
    }
    io.exit(0);
  }

  unawaited(
    server.done.then((_) => shutdown('MCP host closed the stdio channel')),
  );
  for (final signal in [io.ProcessSignal.sigterm, io.ProcessSignal.sigint]) {
    try {
      signal.watch().listen((s) => shutdown('received $s'));
    } on UnsupportedError {
      // sigterm cannot be watched on Windows; stdin EOF still covers it.
    }
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
