import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:vm_service/vm_service.dart';

import '../alerts/alert_detector.dart';
import '../config/capabilities.dart';
import '../config/capture_filter.dart';
import '../state/session.dart';
import '../util/body_decoder.dart';
import '../vm/vm_client.dart';
import 'captures_db.dart';
import 'db_cap.dart';

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

  /// Rolling-cap watchdog cadence (issue #58). At the default 2s tick this
  /// checks DB size every ~60s — off the hot write path. The check is cheap
  /// (one PRAGMA) when under cap; it only evicts when over.
  static const int _capCheckEveryNTicks = 30;

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

  /// Tick counter modulo [_capCheckEveryNTicks].
  int _ticksSinceCapCheck = 0;

  CaptureFilter _captureFilter = CaptureFilter.empty();

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

  /// The filter currently applied by [_tick] — visible so tests (and tools)
  /// can verify a refresh actually reached this writer (RC3).
  CaptureFilter get activeCaptureFilter => _captureFilter;

  void _refreshIgnoredHosts() {
    try {
      _captureFilter = CaptureFilter.build(
        _dao.ignoredHostSet(),
        allowEntries: _dao.captureAllowSet(),
      );
    } catch (_) {
      _captureFilter = CaptureFilter.empty();
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
      if (CapabilityConfig.instance.isEnabled(Category.http)) {
        await _backfillBodies(vm, sid);
      }
      _maybeEnforceDbCap();
    } catch (e, st) {
      io.stderr.writeln('CaptureWriter tick failed: $e\n$st');
    } finally {
      _ticking = false;
    }
  }

  /// Low-frequency rolling-cap watchdog (issue #58). Runs every
  /// [_capCheckEveryNTicks] ticks. Protects every currently-attached session
  /// so live data is never evicted; the manager no-ops when under cap.
  void _maybeEnforceDbCap() {
    _ticksSinceCapCheck++;
    if (_ticksSinceCapCheck < _capCheckEveryNTicks) return;
    _ticksSinceCapCheck = 0;
    if (!DbCapManager.instance.isEnabled) return;
    final protected = SessionRegistry.instance.attached.values
        .map((s) => s.id)
        .toSet();
    DbCapManager.instance.maybeSweep(protectedSessionIds: protected);
  }

  Future<void> _pollHttp(VmClient vm, int sid) async {
    await _maybeRescanIsolates(vm);

    final alertsOn = CapabilityConfig.instance.isEnabled(Category.alerts);
    final searchOn = CapabilityConfig.instance.isEnabled(Category.search);
    final isolates = vm.httpProfilingIsolates;
    if (isolates.isEmpty) return;

    for (final iso in isolates) {
      try {
        final profile = await vm.getHttpProfileForIsolate(
          iso.id,
          updatedSince: _lastCursorPerIsolate[iso.id],
        );
        for (final req in profile.requests) {
          // D10 (audit phase-6): per-request try/catch so a single poisoned
          // request cannot drop the rest of the batch — and, crucially, the
          // cursor is advanced only AFTER the loop, so a mid-batch throw
          // re-delivers the unprocessed tail next tick instead of skipping
          // it forever.
          try {
            if (!_captureFilter.shouldCapture(req.uri)) continue;
            final isNew = _dao.upsertHttpRequest(sid, req, isolateId: iso.id);
            // RC2: URL searchable from first sight, not only after the body
            // backfill (which never ran for empty-body / given-up requests).
            // Only on isNew — the backfill's later full index (url + body
            // text) must not be clobbered by re-delivered updates.
            if (searchOn && isNew) {
              _dao.indexForSearch(
                sessionId: sid,
                vmId: req.id,
                isolateId: iso.id,
                url: req.uri.toString(),
              );
            }
            if (alertsOn) _detector.forHttpRequest(sid, req);
          } catch (e) {
            io.stderr.writeln(
              'CaptureWriter: skipped request ${req.id} on ${iso.id}: $e',
            );
          }
        }
        // Cursor advances only after the batch is durably processed.
        _lastCursorPerIsolate[iso.id] = profile.timestamp;
      } catch (e, st) {
        io.stderr.writeln(
          'CaptureWriter _pollHttp(${iso.id}) failed: $e\n$st',
        );
      }
    }
  }

  Future<void> _pollSockets(VmClient vm, int sid) async {
    for (final iso in vm.httpProfilingIsolates) {
      try {
        final profile = await vm.getSocketProfileForIsolate(iso.id);
        for (final s in profile.sockets) {
          _dao.upsertSocket(sid, s, isolateId: iso.id);
        }
      } catch (_) {
      }
    }
  }

  /// Grace window before a response-incomplete request becomes eligible for a
  /// body-backfill attempt, plus the attempt cap after which the writer gives
  /// up. See [CapturesDao.pendingBodyFetches] and schema v6; this is what
  /// rescues chunked / gzip responses the dart:io profiler never marks
  /// complete (issue #13) without re-polling body-less requests forever.
  static const int _bodyBackfillGraceUs = 3 * 1000 * 1000;
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
          _dao.markBodiesFetched(sid, entry.vmId);
        } else {
          _dao.bumpBodyFetchAttempt(sid, entry.vmId);
        }
      } catch (_) {
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
      final freshIds = {for (final i in fresh) i.id};
      _lastCursorPerIsolate.removeWhere((id, _) => !freshIds.contains(id));
      await _healDegradedCapabilities(vm, fresh);
    } catch (e) {
      io.stderr.writeln('CaptureWriter isolate re-scan failed: $e');
    }
  }

  /// D9 (audit F28): a stream that lost the attach-time race (attach ran
  /// while the app was still booting) left the session permanently degraded
  /// — `http/socket: unavailable` in network_status, forever, with no path
  /// back. On each rescan, retry the enable across ALL isolates for any
  /// capability still marked off; on success flip the AttachedSession flag
  /// (read live by network_status) so the degradation clears within ~20s.
  Future<void> _healDegradedCapabilities(
    VmClient vm,
    List<IsolateInfo> isolates,
  ) async {
    final sid = _sessionId;
    if (sid == null) return;
    // The writer starts before registry.register on attach, so the first
    // tick can see no session — null-safe by design.
    final session = SessionRegistry.instance.attachedById(sid);
    if (session == null) return;
    if (session.httpProfilingEnabled && session.socketProfilingEnabled) return;

    final socketsOn = CapabilityConfig.instance.isEnabled(Category.sockets);
    for (final iso in isolates) {
      if (!session.httpProfilingEnabled) {
        try {
          final state = await vm.enableHttpLoggingForIsolate(iso.id);
          if (state.enabled) {
            session.httpProfilingEnabled = true;
            io.stderr.writeln(
              'CaptureWriter: HTTP capture healed for session $sid on '
              '${iso.id} (attach-time race recovered).',
            );
          }
        } catch (_) {/* still unavailable; retry next rescan */}
      }
      if (socketsOn && !session.socketProfilingEnabled) {
        try {
          if (await vm.enableSocketProfilingForIsolate(iso.id)) {
            session.socketProfilingEnabled = true;
            io.stderr.writeln(
              'CaptureWriter: socket capture healed for session $sid on '
              '${iso.id}.',
            );
          }
        } catch (_) {/* still unavailable */}
      }
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
