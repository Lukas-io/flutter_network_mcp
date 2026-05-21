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
  CaptureWriter({this.pollInterval = const Duration(seconds: 2)});

  final Duration pollInterval;
  final CapturesDao _dao = CapturesDao();
  late final AlertDetector _detector = AlertDetector(_dao);

  VmClient? _vm;
  int? _sessionId;
  Timer? _timer;
  bool _ticking = false;
  DateTime? _lastHttpCursor;
  Set<String> _ignoredHosts = const {};

  bool get isRunning => _timer != null;

  void start(VmClient vm, int sessionId) {
    stop();
    _vm = vm;
    _sessionId = sessionId;
    _lastHttpCursor = null;
    _refreshIgnoredHosts();
    _timer = Timer.periodic(pollInterval, (_) => _tick());
    unawaited(_tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _vm = null;
    _sessionId = null;
    _lastHttpCursor = null;
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
    final profile = await vm.getHttpProfile(updatedSince: _lastHttpCursor);
    _lastHttpCursor = profile.timestamp;
    final alertsOn = CapabilityConfig.instance.isEnabled(Category.alerts);
    for (final req in profile.requests) {
      if (_ignoredHosts.contains(req.uri.host)) continue;
      _dao.upsertHttpRequest(sid, req);
      if (alertsOn) _detector.forHttpRequest(sid, req);
    }
  }

  Future<void> _pollSockets(VmClient vm, int sid) async {
    try {
      final profile = await vm.getSocketProfile();
      for (final s in profile.sockets) {
        _dao.upsertSocket(sid, s);
      }
    } catch (_) {
      // Socket profiling may be unavailable on some embedders; ignore.
    }
  }

  Future<void> _backfillBodies(VmClient vm, int sid) async {
    final pending = _dao.pendingBodyFetches(sid, limit: 10);
    final searchOn = CapabilityConfig.instance.isEnabled(Category.search);
    for (final vmId in pending) {
      try {
        final detail = await vm.getHttpProfileRequest(vmId);
        _dao.storeBodies(sid, detail);
        if (searchOn) _indexForSearch(sid, detail);
      } catch (_) {
        // Request id might have been cleared; we'll retry next tick.
      }
    }
  }

  void _indexForSearch(int sessionId, HttpProfileRequest detail) {
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
