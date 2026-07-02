@Timeout(Duration(seconds: 90))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_network_mcp/src/vm/vm_client.dart';
import 'package:test/test.dart';

/// RC4 (agent-UX audit 2026-07-02, F18): the server must NOTICE the app
/// dying. Before the fix nothing listened to the VM WebSocket closing, so a
/// killed app left a zombie attach that network_status reported as healthy
/// and reads answered with "drive the app to generate traffic".
void main() {
  test('onUnexpectedDisconnect fires when the app process is killed',
      () async {
    final script = File(
      '${Directory.systemTemp.createTempSync('app_death_').path}/app.dart',
    )..writeAsStringSync(
        'import "dart:async";\n'
        'void main() { Timer.periodic(const Duration(seconds: 1), (_) {}); }\n',
      );
    final proc = await Process.start(
      Platform.resolvedExecutable,
      ['--enable-vm-service=0', '--disable-service-auth-codes', script.path],
    );
    // Scrape the VM service URI from stdout.
    final uriLine = await proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .firstWhere((l) => l.contains('Dart VM service'))
        .timeout(const Duration(seconds: 30));
    final httpUri =
        RegExp(r'https?://\S+').firstMatch(uriLine)!.group(0)!;

    final vm = VmClient();
    final died = Completer<void>();
    vm.onUnexpectedDisconnect = died.complete;
    await vm.connect(Uri.parse(httpUri));

    proc.kill(ProcessSignal.sigkill);
    await died.future.timeout(
      const Duration(seconds: 20),
      onTimeout: () => fail(
        'app killed but onUnexpectedDisconnect never fired — zombie-attach '
        'bug (F18) is back',
      ),
    );
    expect(vm.connectedUri, isNull,
        reason: 'client state must be torn down after an app death');
  });

  test('deliberate disconnect does NOT fire onUnexpectedDisconnect',
      () async {
    final script = File(
      '${Directory.systemTemp.createTempSync('app_death2_').path}/app.dart',
    )..writeAsStringSync(
        'import "dart:async";\n'
        'void main() { Timer.periodic(const Duration(seconds: 1), (_) {}); }\n',
      );
    final proc = await Process.start(
      Platform.resolvedExecutable,
      ['--enable-vm-service=0', '--disable-service-auth-codes', script.path],
    );
    final uriLine = await proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .firstWhere((l) => l.contains('Dart VM service'))
        .timeout(const Duration(seconds: 30));
    final httpUri =
        RegExp(r'https?://\S+').firstMatch(uriLine)!.group(0)!;

    final vm = VmClient();
    var fired = false;
    vm.onUnexpectedDisconnect = () => fired = true;
    await vm.connect(Uri.parse(httpUri));
    await vm.disconnect();
    // Give any stray onDone callback time to run before asserting.
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(fired, isFalse,
        reason: 'our own disconnect must never count as an app death');
    proc.kill(ProcessSignal.sigkill);
  });
}
