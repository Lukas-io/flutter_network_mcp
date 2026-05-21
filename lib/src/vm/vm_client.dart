import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

/// Thin wrapper around `package:vm_service`. Connects to a VM service WS URI
/// and provides typed helpers for the `ext.dart.io.*` HTTP + socket profile
/// RPCs.
class VmClient {
  VmService? _service;
  String? _isolateId;
  Uri? _connectedUri;

  bool get isConnected => _service != null;
  Uri? get connectedUri => _connectedUri;
  String? get isolateId => _isolateId;
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

  /// Picks the first running isolate that exposes `ext.dart.io.getHttpProfile`.
  Future<String> pickHttpProfilingIsolate() async {
    final vm = service;
    final info = await vm.getVM();
    for (final ref in info.isolates ?? const <IsolateRef>[]) {
      final id = ref.id;
      if (id == null) continue;
      final isolate = await vm.getIsolate(id);
      final rpcs = isolate.extensionRPCs ?? const <String>[];
      if (rpcs.contains('ext.dart.io.getHttpProfile')) {
        _isolateId = id;
        return id;
      }
    }
    throw StateError(
      'No running isolate exposes dart:io HTTP profiling. '
      'Is the target a Flutter/Dart app that uses HttpClient or package:http?',
    );
  }

  Future<HttpTimelineLoggingState> enableHttpLogging() {
    final id = _requireIsolate();
    return service.httpEnableTimelineLogging(id, true);
  }

  Future<HttpProfile> getHttpProfile({DateTime? updatedSince}) {
    final id = _requireIsolate();
    return service.getHttpProfile(id, updatedSince: updatedSince);
  }

  Future<HttpProfileRequest> getHttpProfileRequest(String requestId) {
    final id = _requireIsolate();
    return service.getHttpProfileRequest(id, requestId);
  }

  Future<Success> clearHttpProfile() {
    final id = _requireIsolate();
    return service.clearHttpProfile(id);
  }

  /// Returns true if socket profiling is available + enabled (best effort).
  Future<bool> enableSocketProfiling() async {
    final id = _requireIsolate();
    final available = await service.isSocketProfilingAvailable(id);
    if (!available) return false;
    final state = await service.socketProfilingEnabled(id, true);
    return state.enabled;
  }

  Future<SocketProfile> getSocketProfile() {
    final id = _requireIsolate();
    return service.getSocketProfile(id);
  }

  Future<Success> clearSocketProfile() {
    final id = _requireIsolate();
    return service.clearSocketProfile(id);
  }

  Future<void> disconnect() async {
    final svc = _service;
    _service = null;
    _isolateId = null;
    _connectedUri = null;
    if (svc != null) await svc.dispose();
  }

  String _requireIsolate() {
    final id = _isolateId;
    if (id == null) throw StateError('No isolate selected. Call attach first.');
    return id;
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
