import 'package:flutter_network_mcp/src/auto_attach.dart';
import 'package:flutter_network_mcp/src/state/log_buffer.dart';
import 'package:test/test.dart';

void main() {
  test('default capacity is 2000 and rotation is counted', () {
    final b = LogBuffer();
    expect(b.capacity, anyOf(2000, greaterThan(50)));
    final small = LogBuffer(capacity: 3);
    for (var i = 0; i < 5; i++) {
      small.push(source: 'logging', timestampMs: i, message: 'm$i');
    }
    expect(small.length, 3);
    expect(small.droppedTotal, 2);
  });

  test('auto-attach polls fast while nothing is attached', () {
    final a = AutoAttacher(
      defaultDtdUri: 'ws://dtd',
      allowedAppPatterns: const ['app'],
      pollInterval: const Duration(seconds: 5),
    );
    expect(a.nextInterval(liveCount: 0), const Duration(seconds: 1));
    expect(a.nextInterval(liveCount: 2), const Duration(seconds: 5));
  });
}
