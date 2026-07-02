import 'package:vm_service/vm_service.dart';

/// D7 (agent-UX audit): classify HTTP exchanges at INGESTION so the same
/// judgement is used everywhere, instead of each consumer re-deriving it
/// (and getting it wrong — e.g. the alert detector flagging every
/// successful WebSocket upgrade as a failed request).

/// A completed WebSocket/HTTP-upgrade handshake: status 101 "Switching
/// Protocols". dart:io then hands the socket to the WebSocket layer and
/// marks the profiled request errored ("Socket has been detached") — which
/// is NOT a request failure, it's a successful upgrade.
bool isWebSocketUpgrade(HttpProfileRequestRef r) {
  final status = r.response?.statusCode;
  if (status == 101) return true;
  final reason = r.response?.reasonPhrase?.toLowerCase();
  return reason == 'switching protocols';
}

/// True when the profiler's error flags are set but the exchange actually
/// succeeded at the protocol level (the upgrade case). Callers should treat
/// this as "not an http_error".
bool isBenignUpgradeError(HttpProfileRequestRef r) {
  final erred =
      (r.request?.hasError ?? false) || (r.response?.hasError ?? false);
  return erred && isWebSocketUpgrade(r);
}

/// Human-facing URL for alert titles / summaries. Strips the meaningless
/// `:0` port the VM emits for some sockets (audit F30: alert titles read
/// `https://host:0/socket.io/...`) and the redundant default ports.
String displayUrl(Uri uri) {
  var u = uri;
  final isDefault = (u.scheme == 'http' && u.port == 80) ||
      (u.scheme == 'https' && u.port == 443) ||
      (u.scheme == 'ws' && u.port == 80) ||
      (u.scheme == 'wss' && u.port == 443);
  if (u.hasPort && (u.port == 0 || isDefault)) {
    u = u.replace(port: null);
  }
  // Uri.replace(port: null) still renders :0 in some SDKs; belt-and-braces.
  return u.toString().replaceFirst(':0/', '/').replaceFirst(RegExp(r':0$'), '');
}
