import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'capture_buffer.dart';

/// VM service extension that surfaces the captured WebSocket buffer to the MCP.
///
/// The MCP polls `ext.flutter_network_mcp.getRealtimeProfile` over the VM
/// service (alongside the SDK's own `getHttpProfile`) and persists what it
/// drains. Mirrors the drain-on-poll contract the SDK profilers already use.
///
/// Method: `ext.flutter_network_mcp.getRealtimeProfile`
/// Params:
///   - `clear=true`: wipe connections + frames, return `{cleared:true}`.
///   - (none): drain. Return captured connections + frames since the last
///     poll, clearing the frame buffer.
/// Result shape (drain):
///   `{"ok":true,"installed":bool,"connections":[...],"frames":[...]}`
class RealtimeExtension {
  RealtimeExtension._();

  static const String methodName = 'ext.flutter_network_mcp.getRealtimeProfile';

  static bool _registered = false;

  /// Registers the extension once. Safe to call repeatedly and safe in builds
  /// where service extensions are unavailable (the call is swallowed). Returns
  /// true if the extension is registered after this call.
  static bool register() {
    if (_registered) return true;
    try {
      developer.registerExtension(methodName, _handle);
      _registered = true;
    } catch (_) {
      // Extensions unavailable (release/AOT) or already registered elsewhere.
      // Capture still works; only the drain channel is absent.
    }
    return _registered;
  }

  /// Builds the JSON-serialisable payload the extension returns. `clear:true`
  /// wipes the buffer; otherwise it drains frames since the last poll. Exposed
  /// for tests; the registered handler just encodes this.
  static Map<String, Object?> buildPayload({bool clear = false}) {
    if (clear) {
      RealtimeCapture.instance.clear();
      return {'ok': true, 'cleared': true};
    }
    return {
      'ok': true,
      'installed': RealtimeCapture.instance.installed,
      ...RealtimeCapture.instance.drain(),
    };
  }

  static Future<developer.ServiceExtensionResponse> _handle(
    String method,
    Map<String, String> parameters,
  ) async {
    try {
      final payload = buildPayload(clear: parameters['clear'] == 'true');
      return developer.ServiceExtensionResponse.result(jsonEncode(payload));
    } catch (e) {
      return developer.ServiceExtensionResponse.error(
        developer.ServiceExtensionResponse.extensionError,
        jsonEncode({'ok': false, 'error': e.toString()}),
      );
    }
  }
}
