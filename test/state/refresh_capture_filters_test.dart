import 'dart:io';

import 'package:flutter_network_mcp/src/state/log_buffer.dart';
import 'package:flutter_network_mcp/src/state/session.dart';
import 'package:flutter_network_mcp/src/storage/capture_writer.dart';
import 'package:flutter_network_mcp/src/storage/captures_db.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:flutter_network_mcp/src/vm/log_stream.dart';
import 'package:flutter_network_mcp/src/vm/vm_client.dart';
import 'package:test/test.dart';

/// RC3 (agent-UX audit 2026-07-02, F20): a mid-session ignored_hosts /
/// capture_allow change must reach EVERY attached session's capture writer.
/// The old refresh path went through `Session.instance.captureWriter`, which
/// resolves to `soleAttached ?? stub` — with 2+ sessions attached the
/// "refresh" hit a stub writer and the change silently never applied.
void main() {
  late Directory dir;

  AttachedSession fakeSession(int id, String uri) => AttachedSession(
        id: id,
        appName: 'app$id',
        vmServiceUri: uri,
        vm: VmClient(),
        captureWriter: CaptureWriter(),
        logBuffer: LogBuffer(),
        logStream: LogStreamSubscriber(),
        attachedAt: DateTime.now(),
        httpProfilingEnabled: true,
        socketProfilingEnabled: true,
      );

  setUp(() {
    dir = Directory.systemTemp.createTempSync('refresh_filters_test_');
    CapturesDatabase.open(dataDir: dir.path);
  });

  tearDown(() async {
    await SessionRegistry.instance.detachAll();
    CapturesDatabase.instance.close();
    dir.deleteSync(recursive: true);
  });

  test('refreshCaptureFilters reaches every attached writer', () {
    final a = fakeSession(1, 'ws://one');
    final b = fakeSession(2, 'ws://two');
    SessionRegistry.instance.register(a);
    SessionRegistry.instance.register(b);

    expect(a.captureWriter.activeCaptureFilter.isActive, isFalse);
    expect(b.captureWriter.activeCaptureFilter.isActive, isFalse);

    CapturesDao().addIgnoredHost('analytics.example.com');
    SessionRegistry.instance.refreshCaptureFilters();

    expect(a.captureWriter.activeCaptureFilter.isActive, isTrue,
        reason: 'first writer must see the new denylist entry');
    expect(b.captureWriter.activeCaptureFilter.isActive, isTrue,
        reason: 'second writer must see it too — the stub-refresh bug '
            'left every non-sole session unfiltered');
    expect(
      a.captureWriter.activeCaptureFilter
          .shouldCapture(Uri.parse('https://analytics.example.com/hit')),
      isFalse,
    );
    expect(
      b.captureWriter.activeCaptureFilter
          .shouldCapture(Uri.parse('https://api.example.com/orders')),
      isTrue,
    );
  });
}
