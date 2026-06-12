/// Companion runtime hooks for `flutter_network_mcp`.
///
/// Captures WebSocket frames the Dart VM service cannot see (everything after
/// the HTTP upgrade is invisible to `getHttpProfile`) and drains them via a VM
/// service extension the MCP polls. See the package README for the one-line
/// install step.
library;

export 'src/ws_frame.dart' show WsFrame, WsFrameDecoder, WsOpcode;
// FlutterNetworkMcpHooks.install() (IOOverrides interception + the VM service
// extension) is added in the next build step.
