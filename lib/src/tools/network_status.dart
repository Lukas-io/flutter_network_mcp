import 'dart:async';

import 'package:dart_mcp/server.dart';
import 'package:path/path.dart' as p;

import '../config/capabilities.dart';
import '../state/session.dart';
import '../state/continuation.dart';
import '../storage/captures_db.dart';
import '../storage/database.dart';
import '../update/update_check.dart';
import '../version.dart';
import '../vm/dtd_discovery.dart';
import '../vm/dtd_probe.dart';
import 'network_attach.dart' as attach_helper;
import 'result.dart';

/// Per-session entry for `network_status.attached[]`. Carries structured
/// capability health (issue #17) so socket/log degradation shows up as a
/// `capabilities` field + `degraded` list, not just a transient attach-time
/// warning the agent may have scrolled past.
Map<String, Object?> attachedStatusEntry(AttachedSession a) {
  final capState = sessionCapabilities(
    httpOk: a.httpProfilingEnabled,
    socketOk: a.socketProfilingEnabled,
    logsOk: a.logStream.isActive,
  );
  return {
    'sessionId': a.id,
    if (a.appName != null) 'appName': a.appName,
    'vmServiceUri': a.vmServiceUri,
    if (a.isolateId != null) 'isolateId': a.isolateId,
    'isolates': [for (final iso in a.isolates) iso.toJson()],
    'attachedAtMs': a.attachedAt.millisecondsSinceEpoch,
    'httpProfilingEnabled': a.httpProfilingEnabled,
    if (a.socketProfilingEnabled) 'socketProfilingEnabled': true,
    'capabilities': capState.capabilities,
    if (capState.degraded.isNotEmpty) 'degraded': capState.degraded,
    // #21: surface the log ring-buffer fill so the agent can reason about
    // rotation proactively (and knows to read now / bump the buffer).
    'logBufferUsed': a.logBuffer.length,
    'logBufferCapacity': a.logBuffer.capacity,
    // #16: hot-restart continuity. When this session id has survived one or
    // more restarts, surface the count + when + where-from so the agent knows
    // the captures it's reading span the restart (and didn't silently reset).
    if (a.reattachCount > 0) 'reattachCount': a.reattachCount,
    if (a.lastReattachAt != null)
      'lastReattachAtMs': a.lastReattachAt!.millisecondsSinceEpoch,
    if (a.previousVmServiceUri != null)
      'previousVmServiceUri': a.previousVmServiceUri,
  };
}

final networkStatusTool = Tool(
  name: 'network_status',
  description:
      'Call first, every session. Reports apps you can attach to (knownApps), '
      'which sessions are attached, queued alerts, enabled capabilities, and '
      'the DB path. Auto-opens DTD so knownApps populates. Follow its '
      'nextSteps.',
  inputSchema: Schema.object(
    properties: {
      'connectDtd': Schema.bool(
        description:
            'Open DTD to populate knownApps. Default true; false for a pure '
            'state read.',
      ),
      'attachIfOne': Schema.bool(
        description:
            'If nothing is attached and exactly one app is visible, attach it '
            '(returned under autoAttached). Default false.',
      ),
    },
  ),
);

FutureOr<CallToolResult> networkStatus(
  CallToolRequest request,
  String? defaultDtdUri,
) async {
  final args = request.arguments ?? const <String, Object?>{};
  final connectDtd = (args['connectDtd'] as bool?) ?? true;
  final attachIfOne = (args['attachIfOne'] as bool?) ?? false;

  final session = Session.instance;
  final registry = SessionRegistry.instance;
  final caps = CapabilityConfig.instance;
  final allEnabled = caps.enabled.length == Category.values.length;

  // Build the per-session attached list. Empty when nothing attached.
  // Phase 10: each entry's `isolates: [...]` lists every HTTP-profiling
  // isolate the capture writer is currently polling. Single-isolate apps
  // see a one-element list; apps spawning workers see more (and grow as
  // the writer's periodic re-scan picks up new isolates).
  final attachedList = <Map<String, Object?>>[
    for (final a in registry.attached.values) attachedStatusEntry(a),
  ];

  final out = <String, Object?>{
    'mcp': _buildMcpBlock(),
    'attachedCount': registry.attachedCount,
    'attached': attachedList,
    // RC4: apps that died while attached — their sessions auto-ended, so
    // the agent reads history instead of polling a corpse.
    if (registry.recentlyDied.isNotEmpty)
      'recentlyEnded': [
        for (final d in registry.recentlyDied)
          {
            'sessionId': d.sessionId,
            if (d.appName != null) 'appName': d.appName,
            'endedReason': 'app exited',
            'diedAtMs': d.diedAt.millisecondsSinceEpoch,
          },
      ],
    // Compact: emit "all" instead of the 8-element list in the common case.
    'capabilities': allEnabled ? 'all' : [for (final c in caps.enabled) c.key],
    'dtd': <String, Object?>{
      'connected': session.dtd.isConnected,
      'uri': session.dtd.connectedUri?.toString(),
      'defaultUri': defaultDtdUri,
    },
    if (session.viewedSessionId != null)
      'viewedSessionId': session.viewedSessionId,
  };

  // Opportunistic DTD connect so knownApps lands on the first status call.
  String? connectError;
  if (connectDtd && !session.dtd.isConnected && defaultDtdUri != null) {
    try {
      await session.dtd
          .connect(Uri.parse(defaultDtdUri))
          .timeout(const Duration(seconds: 5));
      (out['dtd'] as Map<String, Object?>)['connected'] = true;
      (out['dtd'] as Map<String, Object?>)['uri'] = defaultDtdUri;
    } catch (e) {
      connectError = e.toString();
    }
  }

  if (connectError != null) {
    (out['dtd'] as Map<String, Object?>)['connectError'] = connectError;
  }

  // DB-level context: path, session count, and alert totals across all
  // sessions PLUS per-attached-session breakdown when multi-attach.
  if (CapturesDatabase.isOpen) {
    out['dbPath'] = CapturesDatabase.instance.path;
    try {
      final dao = CapturesDao();
      final sessions =
          dao.rawSelect('SELECT COUNT(*) AS n FROM sessions').first['n'];
      out['sessionCount'] = sessions;
      if (caps.isEnabled(Category.alerts)) {
        // 0.6.3 surfaces TWO counts: pendingTotal = distinct signatures
        // (what the agent branches on for "should I drain?"),
        // pendingEvents = raw event volume (helpful when a burst happens
        // and the agent should mention the magnitude without flooding the
        // alert list). They diverge whenever any single alert has
        // occurrence_count > 1.
        final alertsBlock = <String, Object?>{
          'pendingTotal': dao.pendingAlertCount(),
          'pendingEvents': dao.pendingAlertEventCount(),
          'critical': dao.pendingAlertCount(severityMin: 'critical'),
        };
        if (registry.attachedCount >= 2) {
          alertsBlock['perAttached'] = [
            for (final a in registry.attached.values)
              {
                'sessionId': a.id,
                if (a.appName != null) 'appName': a.appName,
                'pending': dao.pendingAlertCount(sessionId: a.id),
                'pendingEvents': dao.pendingAlertEventCount(sessionId: a.id),
              },
          ];
        }
        out['alerts'] = alertsBlock;
      }
    } catch (_) {/* DB might be mid-migration on first run */}
  }

  // App discovery — multi-DTD aware in 0.6.2. Each `flutter run` spawns
  // its own DTD; we probe ALL discovered DTDs in parallel (transient
  // connections, never touches `session.dtd`) so the agent sees every
  // app on the machine, not just the ones under the primary DTD.
  //
  // Each app's `dtdUri` + `workspaceRoot` tells the agent which DTD owns
  // it, so cross-DTD attach can pick the right `dtdUri:` arg if needed
  // (though direct `vmServiceUri:` works without DTD at all).
  try {
    final listings = await DtdProbe.probeAll();
    final knownApps = <Map<String, Object?>>[];
    final seenUris = <String>{};
    for (final listing in listings) {
      for (final app in listing.apps) {
        if (!seenUris.add(app.uri)) continue;
        knownApps.add({
          'name': app.name,
          'uri': app.uri,
          if (app.exposedUri != null) 'exposedUri': app.exposedUri,
          'dtdUri': listing.dtdUri.toString(),
          if (listing.workspaceRoot != null)
            'workspaceRoot': listing.workspaceRoot,
        });
      }
    }

    // Defense-in-depth fallback: if the multi-DTD probe returned nothing
    // (e.g. discovery files unreadable on this system) but the primary
    // DTD IS connected, fall back to the single-DTD path so a working
    // attach stays visible.
    if (knownApps.isEmpty && session.dtd.isConnected) {
      final apps = await session.dtd.getConnectedApps();
      final primaryUri = session.dtd.connectedUri?.toString();
      for (final app in apps) {
        knownApps.add({
          'name': app.name,
          'uri': app.uri,
          if (app.exposedUri != null) 'exposedUri': app.exposedUri,
          if (primaryUri != null) 'dtdUri': primaryUri,
        });
      }
    }

    out['knownApps'] = knownApps;

    // Surface per-DTD errors (e.g. one stale discovery file) so the agent
    // can see why a known DTD didn't contribute apps.
    final probeErrors = [
      for (final listing in listings)
        if (listing.error != null)
          {
            'dtdUri': listing.dtdUri.toString(),
            if (listing.workspaceRoot != null)
              'workspaceRoot': listing.workspaceRoot,
            'error': listing.error,
          },
    ];
    if (probeErrors.isNotEmpty) {
      out['dtdProbeErrors'] = probeErrors;
    }
  } catch (e) {
    out['knownAppsError'] = e.toString();
  }

  // Opt-in one-shot orient+attach: only fires when nothing is attached
  // yet and exactly one app is visible.
  if (attachIfOne && registry.attachedCount == 0) {
    final apps = out['knownApps'] as List?;
    if (apps != null && apps.length == 1 && defaultDtdUri != null) {
      final result = await attach_helper.performAttach(
        defaultDtdUri: defaultDtdUri,
      );
      out['autoAttached'] = result;
      if (result['attached'] == true) {
        // Refresh the attached list now that registration happened.
        out['attachedCount'] = registry.attachedCount;
        (out['attached'] as List).clear();
        for (final a in registry.attached.values) {
          (out['attached'] as List).add(attachedStatusEntry(a));
        }
        // D2/F4: agent-initiated attach — close a shadowing history view.
        attach_helper.closeStaleViewAfterAttach(out);
      }
    }
  }

  // 0.7.3: session continuation. When nothing is currently attached, look
  // at the last-session.json record from a prior MCP-host run and surface
  // it as a `continuation` block so the agent can offer "you were on
  // sanga_mobile 47 min ago — reattach?" — zero user friction across
  // Claude Code reloads / machine reboots.
  if (registry.attachedCount == 0) {
    final cont = SessionContinuation.read();
    if (cont != null) {
      out['continuation'] = cont;
    }
  }

  out['nextSteps'] = _suggestNextSteps(registry, session, out);

  return jsonResult(out);
}

/// Human-readable relative age for a millisecond epoch. "47m" / "3h" /
/// "2d" — coarse on purpose since the agent surfaces this to the user.
String _formatAgo(int tsMs) {
  final delta = DateTime.now().millisecondsSinceEpoch - tsMs;
  if (delta < 60000) return '${(delta / 1000).round()}s';
  if (delta < 3600000) return '${(delta / 60000).round()}m';
  if (delta < 86400000) return '${(delta / 3600000).round()}h';
  return '${(delta / 86400000).round()}d';
}

/// Builds the `mcp` block — agent-readable identity for the running
/// server. Includes version, commit SHA (when known), AOT/JIT mode, the
/// one-command upgrade path, and (when the daily background check has
/// flagged a newer release) the upstream version.
///
/// The agent reads this on every `network_status` call so it can:
///   1. Tell the user what version is running ("you're on 0.6.2").
///   2. Notice when an upgrade is available without scraping stderr.
///   3. Hand the user a paste-ready `flutter_network_mcp update` command.
Map<String, Object?> _buildMcpBlock() {
  final block = <String, Object?>{
    'version': packageVersion,
    if (currentCommitSha() != null) 'commit': currentCommitSha(),
    'isAot': isAotBuild,
    'upgradeCommand': 'flutter_network_mcp update',
  };

  // Read the agent-readable update-status file written by UpdateCheck.
  // Only surface when it flagged a newer release; otherwise the field is
  // omitted so the absence of `updateAvailable` is itself a signal.
  if (CapturesDatabase.isOpen) {
    final dataDir = p.dirname(CapturesDatabase.instance.path);
    final status = UpdateCheck.readStatusFile(dataDir);
    // Re-verify at read time: the status file is written pre-upgrade and
    // the daily check cache blocks a rewrite, so after `update` it can
    // still claim an "available" version that is now current or older
    // (audit: 0.9.18 showing "updateAvailable: 0.9.16").
    if (status != null &&
        status['isNewer'] == true &&
        UpdateCheck.isNewerVersion(
          status['latest'] as String? ?? '',
          packageVersion,
        )) {
      block['updateAvailable'] = {
        'latest': status['latest'],
        if (status['checkedAtMs'] != null) 'checkedAtMs': status['checkedAtMs'],
      };
    }
  }

  return block;
}

/// Returns 1–2 short hints telling the agent what to do given the current
/// state.
List<String> _suggestNextSteps(
  SessionRegistry registry,
  Session session,
  Map<String, Object?> out,
) {
  final steps = <String>[];
  final alertsBlock = out['alerts'] as Map<String, Object?>?;
  final pendingTotal = (alertsBlock?['pendingTotal'] as int?) ?? 0;
  final critical = (alertsBlock?['critical'] as int?) ?? 0;
  final knownApps = out['knownApps'] as List?;
  final attachedCount = registry.attachedCount;

  // Attached path.
  if (attachedCount > 0) {
    if (critical > 0) {
      steps.add('alerts_drain severityMin:"critical" — $critical critical alert(s) pending');
    } else if (pendingTotal > 0) {
      steps.add(
        attachedCount > 1
            ? 'alerts_drain sessionId:<N> — $pendingTotal pending alert(s) across attached sessions (see alerts.perAttached for breakdown)'
            : 'alerts_drain — $pendingTotal pending alert(s) in the attached session',
      );
    }
    if (session.viewedSessionId != null) {
      steps.add('session_close to revert read pointer to live (currently viewing session ${session.viewedSessionId})');
    }
    if (attachedCount > 1) {
      steps.add(
        'Reads must pass sessionId or appNameContains to disambiguate '
        '($attachedCount sessions attached)',
      );
    }
    if (steps.isEmpty) {
      steps.add(
        attachedCount > 1
            ? 'Drive the apps; reads to a specific app need sessionId:<N> from the attached[] list'
            : 'Drive the app, then call network_list (returns nextCursor for incremental polling)',
      );
    }
    return steps;
  }

  // Not attached.
  final dtd = out['dtd'] as Map<String, Object?>;
  final dtdConnected = (dtd['connected'] as bool?) ?? false;
  final defaultUri = dtd['defaultUri'] as String?;

  // 0.7.3: surface the continuation hint FIRST when present — picking up
  // where the previous session left off is usually the right move.
  final cont = out['continuation'] as Map<String, Object?>?;
  final continuationAttachments = cont?['attachments'] as List?;
  if (continuationAttachments != null && continuationAttachments.isNotEmpty) {
    final last = continuationAttachments.first as Map<String, Object?>;
    final lastUri = last['vmServiceUri'] as String?;
    final lastApp = last['appName'] as String? ?? 'previous app';
    final attachedAtMs = last['attachedAtMs'] as int?;
    final ageDesc = attachedAtMs == null
        ? ''
        : ' (~${_formatAgo(attachedAtMs)} ago)';
    if (lastUri != null) {
      steps.add(
        'network_attach vmServiceUri:"$lastUri" — reattach to $lastApp '
        '$ageDesc; previous attachment recorded by 0.7.3 continuation',
      );
    }
  }

  if (!dtdConnected && defaultUri == null) {
    // Before falling back to "ask the user for a URI", peek at the
    // package:dtd discovery directory — there may be a live DTD here
    // that the agent can attach to without involving the user.
    final discovered = DtdDiscovery.discover()
        .where((c) => c.isLive)
        .toList();
    final cwdMatches = discovered.where((c) => c.matchesCwd).toList();
    if (cwdMatches.isNotEmpty) {
      final best = cwdMatches.first;
      steps.add(
        'network_attach dtdUri:"${best.wsUri}" — DTD discovered for cwd '
        '(${best.workspaceRoot}, pid ${best.pid})',
      );
      if (cwdMatches.length > 1) {
        steps.add(
          'network_discover_dtd — ${cwdMatches.length} candidates match cwd, pick another',
        );
      }
      return steps;
    }
    if (discovered.isNotEmpty) {
      steps.add(
        'network_discover_dtd — ${discovered.length} live DTD(s) on this '
        'machine, none in cwd. Pass cwdMatch:false to see them.',
      );
      return steps;
    }
    steps.add(
      'No DTD URI configured and none discovered. Launch a Flutter/Dart '
      'app, then call network_discover_dtd to pick one up automatically — '
      'or start the server with --dtd-uri.',
    );
    return steps;
  }
  if (!dtdConnected && defaultUri != null) {
    steps.add('DTD connect failed; check the URI is still valid (see dtd.connectError)');
    return steps;
  }
  if (knownApps == null || knownApps.isEmpty) {
    steps.add('DTD has no apps registered yet — launch a Flutter app, then re-check');
    return steps;
  }
  if (knownApps.length == 1) {
    steps.add('Call network_attach (one app available — will be auto-picked)');
  } else {
    steps.add(
      'Multiple apps visible (${knownApps.length}); call network_attach with explicit '
      'appNameContains / vmServiceUri. Multi-attach lets you attach to several '
      'at once — repeat the call for each app you want.',
    );
  }
  if (pendingTotal > 0) {
    steps.add(
      '$pendingTotal pending alert(s) across history — alerts_drain sessionId:<N> after attach',
    );
  }
  return steps;
}
