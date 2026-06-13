import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

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

  /// VM service extension the `flutter_network_mcp_hooks` companion registers
  /// to surface captured WebSocket frames (0.9.0 / schema v8).
  static const String realtimeExtension =
      'ext.flutter_network_mcp.getRealtimeProfile';

  /// All known HTTP-profiling isolates, keyed by isolate id. Populated by
  /// [discoverHttpProfilingIsolates] and refreshed by the capture writer's
  /// periodic re-scan (Phase 10).
  final Map<String, IsolateInfo> _isolates = {};

  /// Isolates that expose [realtimeExtension] (the companion package's drain
  /// endpoint). Subset of [_isolates], populated by discovery. Empty when the
  /// app does not install `flutter_network_mcp_hooks`.
  final Set<String> _realtimeIsolates = {};

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

  /// Isolate ids exposing the companion's realtime drain extension.
  List<String> get realtimeIsolates => List.unmodifiable(_realtimeIsolates);

  /// True when the app has installed `flutter_network_mcp_hooks` (at least one
  /// isolate exposes [realtimeExtension]).
  bool get hasRealtimeExtension => _realtimeIsolates.isNotEmpty;

  VmService get service =>
      _service ?? (throw StateError('VM service is not connected.'));

  Future<void> connect(Uri vmServiceUri) async {
    if (_service != null) await disconnect();
    final svc = await vmServiceConnectUri(_toWsUri(vmServiceUri));
    // Zombie-DTD probe: a stale DDS will accept the WS upgrade but never
    // respond to RPCs. Fail fast with a clear error so users don't wait 30+s.
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
  }

  /// Scans the connected VM and returns every isolate that exposes
  /// `ext.dart.io.getHttpProfile`. Caches the result in [_isolates] so
  /// subsequent calls to [httpProfilingIsolates] / [isolateId] / the
  /// back-compat methods see the fresh set. Safe to re-run mid-session
  /// to pick up newly-spawned isolates.
  Future<List<IsolateInfo>> discoverHttpProfilingIsolates() async {
    final vm = service;
    final info = await vm.getVM();
    final found = <String, IsolateInfo>{};
    final realtime = <String>{};
    for (final ref in info.isolates ?? const <IsolateRef>[]) {
      final id = ref.id;
      if (id == null) continue;
      final isolate = await vm.getIsolate(id);
      final rpcs = isolate.extensionRPCs ?? const <String>[];
      if (rpcs.contains('ext.dart.io.getHttpProfile')) {
        found[id] = IsolateInfo(
          id: id,
          name: isolate.name ?? ref.name,
          number: isolate.number ?? ref.number,
        );
      }
      if (rpcs.contains(realtimeExtension)) realtime.add(id);
    }
    _isolates
      ..clear()
      ..addAll(found);
    _realtimeIsolates
      ..clear()
      ..addAll(realtime);
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

  // ===== Per-isolate RPC variants (Phase 9 — explicit isolate id) =====

  Future<HttpTimelineLoggingState> enableHttpLoggingForIsolate(
    String isolateId,
  ) {
    return service.httpEnableTimelineLogging(isolateId, true);
  }

  Future<HttpProfile> getHttpProfileForIsolate(
    String isolateId, {
    DateTime? updatedSince,
  }) {
    return service.getHttpProfile(isolateId, updatedSince: updatedSince);
  }

  Future<HttpProfileRequest> getHttpProfileRequestForIsolate(
    String isolateId,
    String requestId,
  ) {
    return service.getHttpProfileRequest(isolateId, requestId);
  }

  Future<Success> clearHttpProfileForIsolate(String isolateId) {
    return service.clearHttpProfile(isolateId);
  }

  /// Returns true if socket profiling is available + enabled (best effort)
  /// for [isolateId].
  Future<bool> enableSocketProfilingForIsolate(String isolateId) async {
    final available = await service.isSocketProfilingAvailable(isolateId);
    if (!available) return false;
    final state = await service.socketProfilingEnabled(isolateId, true);
    return state.enabled;
  }

  Future<SocketProfile> getSocketProfileForIsolate(String isolateId) {
    return service.getSocketProfile(isolateId);
  }

  Future<Success> clearSocketProfileForIsolate(String isolateId) {
    return service.clearSocketProfile(isolateId);
  }

  /// Drains the companion package's WebSocket capture buffer via
  /// [realtimeExtension]. Returns the decoded payload
  /// (`{ok, installed, connections, frames}` on drain; `{ok, cleared}` when
  /// `clear` is set). Throws if the isolate does not expose the extension
  /// (i.e. the app has not installed `flutter_network_mcp_hooks`).
  Future<Map<String, Object?>> getRealtimeProfile(
    String isolateId, {
    bool clear = false,
  }) async {
    final response = await service.callServiceExtension(
      realtimeExtension,
      isolateId: isolateId,
      args: clear ? {'clear': 'true'} : null,
    );
    return response.json ?? const {};
  }

  // ===== Back-compat single-isolate facades =====
  //
  // These delegate to the per-isolate variants using the first known
  // HTTP-profiling isolate. Existing callers (capture writer Phase 2,
  // single-isolate tests) keep working until Phase 10 wires the writer
  // through the per-isolate path.

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

  Future<void> disconnect() async {
    final svc = _service;
    _service = null;
    _isolates.clear();
    _realtimeIsolates.clear();
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
