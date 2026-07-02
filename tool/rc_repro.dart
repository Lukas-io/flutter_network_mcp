// Repro harness for the missing-batch investigation: attaches the repo's
// own CaptureWriter to a running testbed VM and reports exactly which
// paths land in the DB. Writer errors go to THIS process's stderr.
import 'dart:io';

import 'package:flutter_network_mcp/src/storage/capture_writer.dart';
import 'package:flutter_network_mcp/src/storage/captures_db.dart';
import 'package:flutter_network_mcp/src/storage/database.dart';
import 'package:flutter_network_mcp/src/vm/vm_client.dart';

Future<void> main(List<String> args) async {
  final dataDir = Directory.systemTemp.createTempSync('rc_repro_');
  CapturesDatabase.open(dataDir: dataDir.path);
  final vm = VmClient();
  await vm.connect(Uri.parse(args[0]));
  await vm.discoverHttpProfilingIsolates();
  for (final iso in vm.httpProfilingIsolates) {
    try {
      await vm.enableHttpLoggingForIsolate(iso.id);
    } catch (_) {}
  }
  final dao = CapturesDao();
  final sid = dao.createSession(
    appName: 'repro',
    vmServiceUri: args[0],
    isolateId: null,
    projectPath: null,
  );
  final writer = CaptureWriter()..start(vm, sid);
  stderr.writeln('repro: attached, session $sid — watching for 40s');
  await Future<void>.delayed(const Duration(seconds: 40));
  writer.stop();
  final rows = CapturesDatabase.instance.raw.select(
    'SELECT path, COUNT(*) n, SUM(duration_us IS NULL) in_flight, '
    'MAX(duration_us) max_dur FROM http_requests WHERE session_id=? '
    'GROUP BY path ORDER BY path',
    [sid],
  );
  for (final r in rows) {
    stdout.writeln(
      'PATH ${r['path']}  n=${r['n']}  inFlight=${r['in_flight']}  maxDurUs=${r['max_dur']}',
    );
  }
  exit(0);
}
