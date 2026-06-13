/// Companion runtime hooks for `flutter_network_mcp`.
///
/// Captures WebSocket frames the Dart VM service cannot see (everything after
/// the HTTP upgrade is invisible to `getHttpProfile`) and drains them via a VM
/// service extension the MCP polls.
///
/// Add as a `dev_dependency`, then in `main()`:
///
/// ```dart
/// import 'package:flutter_network_mcp_hooks/flutter_network_mcp_hooks.dart';
///
/// void main() {
///   if (kDebugMode) FlutterNetworkMcpHooks.install();
///   runApp(const MyApp());
/// }
/// ```
library;

export 'src/capture_buffer.dart'
    show CapturedWsConnection, CapturedWsFrame, RealtimeCapture;
export 'src/io_hooks.dart' show FlutterNetworkMcpHooks;
export 'src/ws_frame.dart' show WsFrame, WsFrameDecoder, WsOpcode;
