import 'dart:async';
import 'dart:io' as io;

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

/// Thrown when a VM service RPC does not respond within the configured
/// deadline. A live VM service connection can accept the WebSocket yet stop
/// answering RPCs (app paused at a breakpoint, backgrounded/suspended by the
/// OS, or a wedged DDS). Without a deadline every such call awaits forever;
/// this turns the hang into a typed, catchable failure so tools degrade
/// gracefully instead of blocking for minutes.
class VmRpcTimeoutException implements Exception {
  VmRpcTimeoutException(this.operation, this.deadline);

  /// The RPC that timed out, e.g. `getHttpProfileRequest`.
  final String operation;
  final Duration deadline;

  @override
  String toString() =>
      'VM service did not respond to $operation within '
      '${deadline.inMilliseconds}ms — the app may be paused at a breakpoint, '
      'backgrounded, or the DDS is unresponsive.';
}

/// One isolate worth tracking for HTTP/socket profiling. Captured when
/// [VmClient.discoverHttpProfilingIsolates] runs.
class IsolateInfo {
  IsolateInfo({required this.id, this.name, this.number});

  /// Stable VM service isolate id (e.g. `isolates/1234567890`).
  final String id;

  /// Human-readable name (e.g. `main`, `Isolate-1`, `_worker`).
  final String? name;

  /// VM-assigned isolate number (string in the VM service spec).
  final String? number;

  Map<String, Object?> toJson() => {
        'id': id,
        if (name != null) 'name': name,
        if (number != null) 'number': number,
      };
}

/// Thin wrapper around `package:vm_service`. Connects to a VM service WS URI
/// and provides typed helpers for the `ext.dart.io.*` HTTP + socket profile
/// RPCs.
///
/// **Multi-isolate (Phase 9 / 0.6.0):** the client tracks every isolate in
/// the connected VM that exposes `ext.dart.io.getHttpProfile` — not just
/// the first. Per-isolate RPC variants (`*ForIsolate`) take an explicit
/// isolate id; the back-compat single-isolate methods (`getHttpProfile`,
/// `enableHttpLogging`, etc.) delegate to the first known isolate so
/// callers that haven't been migrated keep working.
class VmClient {
  VmService? _service;
  Uri? _connectedUri;

  /// All known HTTP-profiling isolates, keyed by isolate id. Populated by
  /// [discoverHttpProfilingIsolates] and refreshed by the capture writer's
  /// periodic re-scan (Phase 10).
  final Map<String, IsolateInfo> _isolates = {};

  bool get isConnected => _service != null;
  Uri? get connectedUri => _connectedUri;

  /// Back-compat: first known HTTP-profiling isolate id, or null if no
  /// discovery has run yet (or the connected VM has none). Prefer
  /// [httpProfilingIsolates] in new code.
  String? get isolateId =>
      _isolates.isEmpty ? null : _isolates.keys.first;

  /// Snapshot of every currently-tracked HTTP-profiling isolate.
  List<IsolateInfo> get httpProfilingIsolates =>
      List.unmodifiable(_isolates.values);

  VmService get service =>
      _service ?? (throw StateError('VM service is not connected.'));

  /// Per-RPC deadline. Every `ext.dart.io.*` call is bounded by this so a
  /// live-but-unresponsive VM can never hang a tool indefinitely. Defaults to
  /// 10s (40x the slowest normal call observed in telemetry); override with
  /// `FLUTTER_NETWORK_MCP_RPC_TIMEOUT_MS` (clamped to a 1s floor).
  static final Duration rpcDeadline = _deadlineFromEnv();

  static Duration _deadlineFromEnv() {
    final raw =
        int.tryParse(io.Platform.environment['FLUTTER_NETWORK_MCP_RPC_TIMEOUT_MS'] ?? '');
    if (raw == null || raw < 1000) return const Duration(seconds: 10);
    return Duration(milliseconds: raw);
  }

  /// Wraps a VM service RPC [future] with [rpcDeadline]. On expiry it throws a
  /// [VmRpcTimeoutException] tagged with [operation] instead of awaiting
  /// forever. The underlying request is abandoned (not cancellable in the VM
  /// service protocol), which is harmless: the data lives in the VM's ring
  /// buffer and a later call re-reads it. Visible for testing via [boundForTest].
  Future<T> _bounded<T>(String operation, Future<T> future) {
    return future.timeout(
      rpcDeadline,
      onTimeout: () => throw VmRpcTimeoutException(operation, rpcDeadline),
    );
  }

  /// Test seam for the bounded-RPC behaviour without a live VM.
  static Future<T> boundForTest<T>(
    String operation,
    Future<T> future, {
    required Duration deadline,
  }) {
    return future.timeout(
      deadline,
      onTimeout: () => throw VmRpcTimeoutException(operation, deadline),
    );
  }

  /// RC4: invoked at most once when the VM WebSocket closes WITHOUT
  /// [disconnect] having been called — i.e. the app process went away
  /// (quit, crash, device disconnect, `flutter run` stopped). Deliberate
  /// [disconnect] / reconnect never fires it.
  void Function()? onUnexpectedDisconnect;
  bool _deliberateDisconnect = false;

  Future<void> connect(Uri vmServiceUri) async {
    if (_service != null) await disconnect();
    final svc = await vmServiceConnectUri(_toWsUri(vmServiceUri));
    try {
      await svc.getVersion().timeout(const Duration(seconds: 5));
    } on Object catch (_) {
      await svc.dispose();
      throw StateError(
        'VM service at $vmServiceUri accepted the connection but did not '
        'respond to getVersion() within 5s. The DTD/DDS instance is likely '
        'stale — restart the Flutter app to spawn a fresh one.',
      );
    }
    _service = svc;
    _connectedUri = vmServiceUri;
    _deliberateDisconnect = false;
    unawaited(svc.onDone.then((_) {
      // Stale callback from a previous connection, or a disconnect() we
      // initiated ourselves — not an app death.
      if (_deliberateDisconnect || !identical(_service, svc)) return;
      _service = null;
      _isolates.clear();
      _connectedUri = null;
      onUnexpectedDisconnect?.call();
    }));
  }

  /// Scans the connected VM and returns every isolate that exposes
  /// `ext.dart.io.getHttpProfile`. Caches the result in [_isolates] so
  /// subsequent calls to [httpProfilingIsolates] / [isolateId] / the
  /// back-compat methods see the fresh set. Safe to re-run mid-session
  /// to pick up newly-spawned isolates.
  Future<List<IsolateInfo>> discoverHttpProfilingIsolates() async {
    final vm = service;
    final info = await _bounded('getVM', vm.getVM());
    final found = <String, IsolateInfo>{};
    for (final ref in info.isolates ?? const <IsolateRef>[]) {
      final id = ref.id;
      if (id == null) continue;
      final isolate = await _bounded('getIsolate', vm.getIsolate(id));
      final rpcs = isolate.extensionRPCs ?? const <String>[];
      if (rpcs.contains('ext.dart.io.getHttpProfile')) {
        found[id] = IsolateInfo(
          id: id,
          name: isolate.name ?? ref.name,
          number: isolate.number ?? ref.number,
        );
      }
    }
    _isolates
      ..clear()
      ..addAll(found);
    return httpProfilingIsolates;
  }

  /// Back-compat: returns the first HTTP-profiling isolate id. Runs
  /// [discoverHttpProfilingIsolates] when the cache is empty. Throws
  /// [StateError] when no isolate qualifies.
  Future<String> pickHttpProfilingIsolate() async {
    if (_isolates.isEmpty) {
      await discoverHttpProfilingIsolates();
    }
    if (_isolates.isEmpty) {
      throw StateError(
        'No running isolate exposes dart:io HTTP profiling. '
        'Is the target a Flutter/Dart app that uses HttpClient or package:http?',
      );
    }
    return _isolates.keys.first;
  }

  Future<HttpTimelineLoggingState> enableHttpLoggingForIsolate(
    String isolateId,
  ) {
    return _bounded(
      'httpEnableTimelineLogging',
      service.httpEnableTimelineLogging(isolateId, true),
    );
  }

  Future<HttpProfile> getHttpProfileForIsolate(
    String isolateId, {
    DateTime? updatedSince,
  }) {
    return _bounded(
      'getHttpProfile',
      service.getHttpProfile(isolateId, updatedSince: updatedSince),
    );
  }

  Future<HttpProfileRequest> getHttpProfileRequestForIsolate(
    String isolateId,
    String requestId,
  ) {
    return _bounded(
      'getHttpProfileRequest',
      service.getHttpProfileRequest(isolateId, requestId),
    );
  }

  Future<Success> clearHttpProfileForIsolate(String isolateId) {
    return _bounded('clearHttpProfile', service.clearHttpProfile(isolateId));
  }

  /// Returns true if socket profiling is available + enabled (best effort)
  /// for [isolateId].
  Future<bool> enableSocketProfilingForIsolate(String isolateId) async {
    final available = await _bounded(
      'isSocketProfilingAvailable',
      service.isSocketProfilingAvailable(isolateId),
    );
    if (!available) return false;
    final state = await _bounded(
      'socketProfilingEnabled',
      service.socketProfilingEnabled(isolateId, true),
    );
    return state.enabled;
  }

  Future<SocketProfile> getSocketProfileForIsolate(String isolateId) {
    return _bounded('getSocketProfile', service.getSocketProfile(isolateId));
  }

  Future<Success> clearSocketProfileForIsolate(String isolateId) {
    return _bounded('clearSocketProfile', service.clearSocketProfile(isolateId));
  }

  Future<HttpTimelineLoggingState> enableHttpLogging() {
    return enableHttpLoggingForIsolate(_requireIsolate());
  }

  Future<HttpProfile> getHttpProfile({DateTime? updatedSince}) {
    return getHttpProfileForIsolate(
      _requireIsolate(),
      updatedSince: updatedSince,
    );
  }

  Future<HttpProfileRequest> getHttpProfileRequest(String requestId) {
    return getHttpProfileRequestForIsolate(_requireIsolate(), requestId);
  }

  Future<Success> clearHttpProfile() {
    return clearHttpProfileForIsolate(_requireIsolate());
  }

  Future<bool> enableSocketProfiling() {
    return enableSocketProfilingForIsolate(_requireIsolate());
  }

  Future<SocketProfile> getSocketProfile() {
    return getSocketProfileForIsolate(_requireIsolate());
  }

  Future<Success> clearSocketProfile() {
    return clearSocketProfileForIsolate(_requireIsolate());
  }

  /// The target VM's start time (ms since epoch), best-effort. Used at
  /// attach to tell the agent how long the app was running BEFORE capture
  /// began — dart:io HTTP/socket profiling records nothing before it is
  /// enabled, so pre-attach traffic is simply absent (audit F17). Returns
  /// null if the VM doesn't report it or the call fails.
  Future<int?> vmStartTimeMs() async {
    try {
      final vm = await _bounded('getVM', service.getVM());
      final t = vm.startTime;
      return (t == null || t <= 0) ? null : t;
    } catch (_) {
      return null;
    }
  }

  Future<void> disconnect() async {
    _deliberateDisconnect = true;
    final svc = _service;
    _service = null;
    _isolates.clear();
    _connectedUri = null;
    if (svc != null) await svc.dispose();
  }

  String _requireIsolate() {
    if (_isolates.isEmpty) {
      throw StateError('No isolate selected. Call attach first.');
    }
    return _isolates.keys.first;
  }

  /// Normalizes a VM service URI to a ws:// path ending in `/ws`.
  static String _toWsUri(Uri uri) {
    if (uri.scheme == 'ws' || uri.scheme == 'wss') {
      return uri.toString();
    }
    final scheme = uri.scheme == 'https' ? 'wss' : 'ws';
    final segments = [...uri.pathSegments.where((s) => s.isNotEmpty)];
    if (segments.isEmpty || segments.last != 'ws') segments.add('ws');
    return Uri(
      scheme: scheme,
      host: uri.host,
      port: uri.port,
      pathSegments: segments,
    ).toString();
  }
}
