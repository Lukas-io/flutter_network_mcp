import 'package:flutter_network_mcp/src/config/capabilities.dart';
import 'package:test/test.dart';

/// Issue #17: degraded capabilities must surface as a structured field, and a
/// globally-disabled category must NOT be reported as `degraded` (it's an
/// intentional config choice, not a runtime failure).
void main() {
  group('capabilityState', () {
    test('disabled when the category is off in config', () {
      expect(capabilityState(enabled: false, runtimeOk: true), 'disabled');
      expect(capabilityState(enabled: false, runtimeOk: false), 'disabled');
    });
    test('ok when enabled and the stream started', () {
      expect(capabilityState(enabled: true, runtimeOk: true), 'ok');
    });
    test('unavailable when enabled but the stream failed', () {
      expect(capabilityState(enabled: true, runtimeOk: false), 'unavailable');
    });
  });

  group('sessionCapabilities', () {
    setUp(() {
      // Reset to all-on between tests.
      CapabilityConfig.install(CapabilityConfig.fromFlags());
    });

    test('all healthy → no degraded entries', () {
      final r = sessionCapabilities(httpOk: true, socketOk: true, logsOk: true);
      expect(r.capabilities,
          {'http': 'ok', 'socket': 'ok', 'logs': 'ok'});
      expect(r.degraded, isEmpty);
    });

    test('enabled-but-failed socket is flagged degraded', () {
      final r =
          sessionCapabilities(httpOk: true, socketOk: false, logsOk: true);
      expect(r.capabilities['socket'], 'unavailable');
      expect(r.degraded, ['socket']);
    });

    test('globally-disabled category is "disabled", not "degraded"', () {
      CapabilityConfig.install(
          CapabilityConfig.fromFlags(denylist: 'sockets'));
      final r =
          sessionCapabilities(httpOk: true, socketOk: false, logsOk: true);
      expect(r.capabilities['socket'], 'disabled');
      expect(r.degraded, isEmpty,
          reason: 'turning a capability off on purpose is not degradation');
    });
  });
}
