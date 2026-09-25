import 'package:dtd/dtd.dart';

import 'vm_uri.dart';

/// Thin wrapper around `package:dtd`. Holds an active DTD connection and
/// exposes the few calls Phase 1 needs.
class DtdClient {
  DartToolingDaemon? _dtd;
  Uri? _connectedUri;

  bool get isConnected => _dtd != null;
  Uri? get connectedUri => _connectedUri;

  Future<void> connect(Uri uri) async {
    if (_dtd != null) await disconnect();
    _dtd = await DartToolingDaemon.connect(uri);
    _connectedUri = uri;
  }

  /// Returns the VM service connections DTD knows about.
  ///
  /// Each entry exposes a `uri` (a `ws://...` URL) and optional `name`
  /// (e.g. `Flutter - iPhone 17 - Package: sanga_mobile`).
  Future<List<VmServiceInfo>> getConnectedApps() async {
    final dtd = _requireConnected();
    final response = await dtd.getVmServices();
    // One spelling per VM from the start, so every comparison against attached sessions matches.
    return [
      for (final i in response.vmServicesInfos)
        VmServiceInfo(
          uri: canonicalVmServiceUri(i.uri),
          exposedUri: i.exposedUri,
          name: i.name,
        ),
    ];
  }

  Future<void> disconnect() async {
    final dtd = _dtd;
    _dtd = null;
    _connectedUri = null;
    if (dtd != null) await dtd.close();
  }

  DartToolingDaemon _requireConnected() {
    final dtd = _dtd;
    if (dtd == null) throw StateError('DTD is not connected.');
    return dtd;
  }
}
