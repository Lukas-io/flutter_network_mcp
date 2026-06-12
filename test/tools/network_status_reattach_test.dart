import 'package:flutter_network_mcp/src/state/log_buffer.dart';
import 'package:flutter_network_mcp/src/state/session.dart';
import 'package:flutter_network_mcp/src/storage/capture_writer.dart';
import 'package:flutter_network_mcp/src/tools/network_status.dart';
import 'package:flutter_network_mcp/src/vm/log_stream.dart';
import 'package:flutter_network_mcp/src/vm/vm_client.dart';
import 'package:test/test.dart';

/// Issue #16: hot-restart continuity is a first-class, agent-visible fact.
/// network_status surfaces how many restarts a live session survived, when,
/// and the URI it moved off of, so the agent knows its captures span the
/// restart rather than silently resetting.
void main() {
  AttachedSession make({
    int reattachCount = 0,
    DateTime? lastReattachAt,
    String? previousVmServiceUri,
  }) =>
      AttachedSession(
        id: 5,
        appName: 'Flutter - Device: iPhone 17 - Package: sanga_mobile',
        vmServiceUri: 'ws://new',
        isolateId: 'isolates/1',
        vm: VmClient(),
        captureWriter: CaptureWriter(),
        logBuffer: LogBuffer(),
        logStream: LogStreamSubscriber(),
        attachedAt: DateTime.fromMillisecondsSinceEpoch(1000),
        httpProfilingEnabled: true,
        socketProfilingEnabled: false,
        lastReattachAt: lastReattachAt,
        previousVmServiceUri: previousVmServiceUri,
        reattachCount: reattachCount,
      );

  test('a never-migrated session omits the reattach fields', () {
    final e = attachedStatusEntry(make());
    expect(e.containsKey('reattachCount'), isFalse);
    expect(e.containsKey('lastReattachAtMs'), isFalse);
    expect(e.containsKey('previousVmServiceUri'), isFalse);
  });

  test('a migrated session surfaces count, when, and previous URI', () {
    final e = attachedStatusEntry(make(
      reattachCount: 2,
      lastReattachAt: DateTime.fromMillisecondsSinceEpoch(9000),
      previousVmServiceUri: 'ws://old',
    ));
    expect(e['reattachCount'], 2);
    expect(e['lastReattachAtMs'], 9000);
    expect(e['previousVmServiceUri'], 'ws://old');
    // The session id is stable across the restart.
    expect(e['sessionId'], 5);
  });
}
