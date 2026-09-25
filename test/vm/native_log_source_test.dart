import 'package:flutter_network_mcp/src/vm/native_log_source.dart';
import 'package:test/test.dart';

void main() {
  test('parses the DTD app name into device and package', () {
    final p = NativeLogSource.parseAppName(
        'Kind: Flutter - Device: iPhone 17 - Package: sanga_mobile');
    expect(p.device, 'iPhone 17');
    expect(p.package, 'sanga_mobile');
    expect(NativeLogSource.looksLikeIos('iPhone 17'), isTrue);
    expect(NativeLogSource.looksLikeIos('sdk gphone64 arm64'), isFalse);
  });

  test('finds a booted simulator by name, exact before prefix', () {
    const json = '{"devices": {"rt": ['
        '{"name": "iPhone 17 Pro", "udid": "PRO", "state": "Booted"},'
        '{"name": "iPhone 17", "udid": "PLAIN", "state": "Booted"},'
        '{"name": "iPhone Air", "udid": "AIR", "state": "Shutdown"}]}}';
    expect(NativeLogSource.udidFromSimctlJson(json, 'iPhone 17'), 'PLAIN');
    expect(NativeLogSource.udidFromSimctlJson(json, 'iphone 17 p'), 'PRO');
    expect(NativeLogSource.udidFromSimctlJson(json, 'iPhone Air'), isNull);
  });

  test('finds an Android serial by model, or the only device', () {
    const text = 'List of devices attached\n'
        'emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a\n';
    expect(NativeLogSource.serialFromAdbDevices(text, 'sdk gphone64 arm64'), 'emulator-5554');
    expect(NativeLogSource.serialFromAdbDevices(text, 'Pixel 8'), 'emulator-5554');
  });

  test('parses simctl compact and logcat lines', () {
    final s = NativeLogSource.parseSimctlLine(
        '2026-09-04 03:10:12.123 E Runner[1234:abc1] [com.posthog:events] queue flushed');
    expect(s?.level, 1000);
    expect(s?.logger, 'Runner com.posthog:events');
    expect(s?.message, 'queue flushed');
    final l = NativeLogSource.parseLogcatLine('09-04 03:10:12.123 W/PostHog( 1234): retrying');
    expect(l?.level, 900);
    expect(l?.logger, 'PostHog');
    expect(l?.message, 'retrying');
    expect(NativeLogSource.parseLogcatLine('garbage'), isNull);
  });
}
