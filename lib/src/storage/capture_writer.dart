import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:vm_service/vm_service.dart';

import '../alerts/alert_detector.dart';
import '../config/capabilities.dart';
import '../util/body_decoder.dart';
import '../vm/vm_client.dart';
import 'captures_db.dart';

/// Periodically polls the VM service and writes HTTP + socket data into the
/// captures DB. Also drives the alert detector on each upserted request and
/// indexes utf8-decoded bodies into the FTS search table.
class CaptureWriter {
  CaptureWriter({Duration? pollInterval})
      : pollInterval = pollInterval ?? _envPollInterval();

  final Duration pollInterval;

  /// Reads `FLUTTER_NETWORK_MCP_POLL_MS` env var (50–60000). Defaults to 2000.
  static Duration _envPollInterval() {
    final raw = io.Platform.environment['FLUTTER_NETWORK_MCP_POLL_MS'];
    final parsed = raw == null ? null : int.tryParse(raw);
    if (parsed == null) return const Duration(seconds: 2);
    final clamped = parsed < 50 ? 50 : (parsed > 60000 ? 60000 : parsed);
    return Duration(milliseconds: clamped);
  }
  final CapturesDao _dao = CapturesDao();
  late final AlertDetector _detector = AlertDetector(_dao);

  /// Periodic isolate re-scan cadence — every Nth tick we re-discover
  /// HTTP-profiling isolates so newly-spawned ones get picked up
  /// without forcing a manual re-attach. At the default 2s tick this
  /// means ~20s discovery lag for fresh isolates.
  static const int _rescanEveryNTicks = 10;

  VmClient? _vm;
  int? _sessionId;
  Timer? _timer;
  bool _ticking = false;

  /// Per-isolate HTTP cursor map (multi-isolate Phase 10). Each isolate
  /// runs at its own request cadence, so each needs its own incremental
  /// "updatedSince" cursor or we drop requests on the floor.
  final Map<String, DateTime> _lastCursorPerIsolate = {};

  /// Tick counter modulo [_rescanEveryNTicks].
  int _ticksSinceRescan = 0;

  Set<String> _ignoredHosts = const {};

  bool get isRunning => _timer != null;

  void start(VmClient vm, int sessionId) {
    stop();
    _vm = vm;
    _sessionId = sessionId;
    _lastCursorPerIsolate.clear();
    _ticksSinceRescan = 0;
    _refreshIgnoredHosts();
    _timer = Timer.periodic(pollInterval, (_) => _tick());
    unawaited(_tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _vm = null;
    _sessionId = null;
    _lastCursorPerIsolate.clear();
    _ticksSinceRescan = 0;
    _ticking = false;
  }

  /// Forces a re-read of the ignored_hosts table — called by the tool that
  /// adds/removes entries so changes take effect before the next tick.
  void refreshIgnoredHosts() => _refreshIgnoredHosts();

  void _refreshIgnoredHosts() {
    try {
      _ignoredHosts = _dao.ignoredHostSet();
    } catch (_) {
      _ignoredHosts = const {};
    }
  }

  Future<void> _tick() async {
    if (_ticking) return;
    _ticking = true;
    final vm = _vm;
    final sid = _sessionId;
    if (vm == null || sid == null) {
      _ticking = false;
      return;
    }
    try {
      if (CapabilityConfig.instance.isEnabled(Category.http)) {
        await _pollHttp(vm, sid);
      }
      if (CapabilityConfig.instance.isEnabled(Category.sockets)) {
        await _pollSockets(vm, sid);
      }
      if (CapabilityConfig.instance.isEnabled(Category.realtime)) {
        await _pollRealtime(vm, sid);
      }
      if (CapabilityConfig.instance.isEnabled(Category.http)) {
        await _backfillBodies(vm, sid);
      }
    } catch (e, st) {
      io.stderr.writeln('CaptureWriter tick failed: $e\n$st');
    } finally {
      _ticking = false;
    }
  }

  Future<void> _pollHttp(VmClient vm, int sid) async {
    await _maybeRescanIsolates(vm);

    final alertsOn = CapabilityConfig.instance.isEnabled(Category.alerts);
    final isolates = vm.httpProfilingIsolates;
    if (isolates.isEmpty) return;

    // Poll each known isolate; tag every captured request with the
    // isolate it came from so per-isolate filtering downstream works.
    // Per-isolate try/catch so one bad isolate doesn't stop the others.
    for (final iso in isolates) {
      try {
        final profile = await vm.getHttpProfileForIsolate(
          iso.id,
          updatedSince: _lastCursorPerIsolate[iso.id],
        );
        _lastCursorPerIsolate[iso.id] = profile.timestamp;
        for (final req in profile.requests) {
          if (_ignoredHosts.contains(req.uri.host)) continue;
          _dao.upsertHttpRequest(sid, req, isolateId: iso.id);
          if (alertsOn) _detector.forHttpRequest(sid, req);
        }
      } catch (e, st) {
        io.stderr.writeln(
          'CaptureWriter _pollHttp(${iso.id}) failed: $e\n$st',
        );
      }
    }
  }

  Future<void> _pollSockets(VmClient vm, int sid) async {
    // Don't re-scan here — _pollHttp handles re-scan, and sockets share
    // the same isolate set. Avoids double discovery RPCs per tick.
    for (final iso in vm.httpProfilingIsolates) {
      try {
        final profile = await vm.getSocketProfileForIsolate(iso.id);
        for (final s in profile.sockets) {
          _dao.upsertSocket(sid, s, isolateId: iso.id);
        }
      } catch (_) {
        // Socket profiling may be unavailable on some embedders; ignore.
      }
    }
  }

  /// Drains the companion package's WebSocket capture buffer over its VM
  /// service extension and persists connections + frames. Only isolates that
  /// registered the extension respond; apps without `flutter_network_mcp_hooks`
  /// simply have no realtime isolates, so this is a no-op for them.
  Future<void> _pollRealtime(VmClient vm, int sid) async {
    // The HTTP path drives isolate discovery; when http is disabled, kick off
    // a one-time discovery here so the companion isolate is found.
    if (vm.realtimeIsolates.isEmpty && vm.httpProfilingIsolates.isEmpty) {
      try {
        await vm.discoverHttpProfilingIsolates();
      } catch (_) {/* transient; retry next tick */}
    }
    for (final isoId in vm.realtimeIsolates) {
      try {
        final profile = await vm.getRealtimeProfile(isoId);
        final connections = profile['connections'];
        if (connections is List) {
          for (final c in connections) {
            if (c is! Map || c['id'] is! num) continue;
            _dao.upsertWsConnection(
              sid,
              connId: (c['id'] as num).toInt(),
              host: c['host'] as String?,
              port: (c['port'] as num?)?.toInt(),
              path: c['path'] as String?,
              startedMs: (c['startedMs'] as num?)?.toInt(),
              isolateId: isoId,
            );
          }
        }
        final frames = profile['frames'];
        if (frames is List) {
          for (final f in frames) {
            if (f is! Map || f['connectionId'] is! num) continue;
            _dao.insertWsFrame(
              sid,
              connId: (f['connectionId'] as num).toInt(),
              tsMs: (f['tsMs'] as num?)?.toInt(),
              direction: (f['dir'] as String?) ?? 'in',
              opcode: (f['opcode'] as String?) ?? 'binary',
              length: (f['len'] as num?)?.toInt(),
              isText: f['isText'] == true,
              compressed: f['compressed'] == true,
              preview: f['preview'] as String?,
            );
          }
        }
      } catch (e, st) {
        io.stderr.writeln('CaptureWriter _pollRealtime($isoId) failed: $e\n$st');
      }
    }
  }

  /// Grace window before a response-incomplete request becomes eligible for a
  /// body-backfill attempt, plus the attempt cap after which the writer gives
  /// up. See [CapturesDao.pendingBodyFetches] and schema v6; this is what
  /// rescues chunked / gzip responses the dart:io profiler never marks
  /// complete (issue #13) without re-polling body-less requests forever.
  static const int _bodyBackfillGraceUs = 3 * 1000 * 1000; // 3s
  static const int _maxBodyFetchAttempts = 3;

  Future<void> _backfillBodies(VmClient vm, int sid) async {
    final staleBeforeUs =
        DateTime.now().microsecondsSinceEpoch - _bodyBackfillGraceUs;
    final pending = _dao.pendingBodyFetches(
      sid,
      limit: 10,
      staleBeforeUs: staleBeforeUs,
      maxAttempts: _maxBodyFetchAttempts,
    );
    final searchOn = CapabilityConfig.instance.isEnabled(Category.search);
    for (final entry in pending) {
      // Use the recorded isolate id when known; fall back to the first
      // tracked isolate for pre-v4 rows (NULL isolate_id) or rows
      // inserted before isolate tagging took effect mid-session.
      final isolateId = entry.isolateId ?? vm.isolateId;
      if (isolateId == null) continue;
      try {
        final detail = await vm.getHttpProfileRequestForIsolate(
          isolateId,
          entry.vmId,
        );
        final hasBody = (detail.requestBody?.isNotEmpty ?? false) ||
            (detail.responseBody?.isNotEmpty ?? false);
        if (hasBody) {
          _dao.storeBodies(sid, detail);
          if (searchOn) _indexForSearch(sid, detail, isolateId: isolateId);
        } else if (entry.isComplete) {
          // Complete and genuinely body-less (204 / HEAD / empty); terminal.
          _dao.markBodiesFetched(sid, entry.vmId);
        } else {
          // Response-incomplete, no body yet; count the attempt so the gate
          // eventually drops it instead of re-polling forever.
          _dao.bumpBodyFetchAttempt(sid, entry.vmId);
        }
      } catch (_) {
        // Request id might have been cleared from the VM ring buffer. For
        // incomplete rows, count it so they age out; complete rows retry.
        if (!entry.isComplete) _dao.bumpBodyFetchAttempt(sid, entry.vmId);
      }
    }
  }

  /// On the first tick and every [_rescanEveryNTicks] ticks thereafter,
  /// re-discover HTTP-profiling isolates so newly-spawned ones come
  /// into capture without forcing a manual re-attach. Newly-found
  /// isolates get their profiling enabled before we poll them.
  Future<void> _maybeRescanIsolates(VmClient vm) async {
    final firstTick = vm.httpProfilingIsolates.isEmpty;
    final dueForRescan = _ticksSinceRescan >= _rescanEveryNTicks;
    if (!firstTick && !dueForRescan) {
      _ticksSinceRescan++;
      return;
    }
    _ticksSinceRescan = 0;

    try {
      final before = {for (final i in vm.httpProfilingIsolates) i.id};
      final fresh = await vm.discoverHttpProfilingIsolates();
      // Enable HTTP (+ optionally socket) profiling on every newly-
      // discovered isolate so its requests start flowing into our polls.
      final socketsOn =
          CapabilityConfig.instance.isEnabled(Category.sockets);
      for (final iso in fresh) {
        if (before.contains(iso.id)) continue;
        try {
          await vm.enableHttpLoggingForIsolate(iso.id);
        } catch (_) {/* embedder may not support per-isolate enable */}
        if (socketsOn) {
          try {
            await vm.enableSocketProfilingForIsolate(iso.id);
          } catch (_) {/* harmless */}
        }
      }
      // Drop cursors for isolates that vanished (e.g. compute isolate
      // finished). Their captured rows stay in the DB.
      final freshIds = {for (final i in fresh) i.id};
      _lastCursorPerIsolate.removeWhere((id, _) => !freshIds.contains(id));
    } catch (e) {
      io.stderr.writeln('CaptureWriter isolate re-scan failed: $e');
    }
  }

  void _indexForSearch(
    int sessionId,
    HttpProfileRequest detail, {
    String? isolateId,
  }) {
    final url = detail.uri.toString();
    final reqHeaders =
        detail.request?.hasError == true ? null : detail.request?.headers;
    final respHeaders =
        detail.response?.hasError == true ? null : detail.response?.headers;
    final reqCt = firstHeader(reqHeaders, 'content-type');
    final respCt = firstHeader(respHeaders, 'content-type');
    _dao.indexForSearch(
      sessionId: sessionId,
      vmId: detail.id,
      isolateId: isolateId,
      url: url,
      requestText: _safeUtf8(detail.requestBody, reqCt),
      responseText: _safeUtf8(detail.responseBody, respCt),
    );
  }

  String? _safeUtf8(Uint8List? bytes, String? contentType) {
    if (bytes == null || bytes.isEmpty) return null;
    final ct = contentType?.toLowerCase() ?? '';
    final textish = ct.contains('json') ||
        ct.contains('xml') ||
        ct.contains('text') ||
        ct.contains('javascript') ||
        ct.contains('graphql') ||
        ct.contains('form-urlencoded');
    if (!textish) return null;
    try {
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return null;
    }
  }
}
