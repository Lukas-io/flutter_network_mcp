// Probe script — exercises the same code paths as network_attach without MCP.
// Useful for diagnosing DTD/VM service connectivity outside the stdio loop.
//
// Run: dart run tool/probe.dart <dtdWsUri>

import 'dart:io';

import 'package:flutter_network_mcp/src/state/session.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('Usage: dart run tool/probe.dart <dtdWsUri>');
    exit(2);
  }
  final dtdUri = args.first;
  final s = Session.instance;

  stderr.writeln('[1] connecting to DTD: $dtdUri');
  await s.dtd.connect(Uri.parse(dtdUri));

  stderr.writeln('[2] fetching connected apps');
  final apps = await s.dtd.getConnectedApps();
  for (final a in apps) {
    stderr.writeln('    - ${a.name} @ ${a.uri}');
  }
  if (apps.isEmpty) {
    stderr.writeln('No apps. Bye.');
    await s.detach();
    return;
  }

  stderr.writeln('[3] connecting to VM service: ${apps.first.uri}');
  await s.vm.connect(Uri.parse(apps.first.uri));

  stderr.writeln('[4] picking HTTP-profiling isolate');
  final id = await s.vm.pickHttpProfilingIsolate();
  stderr.writeln('    isolate: $id');

  stderr.writeln('[5] enabling HTTP logging');
  final state = await s.vm.enableHttpLogging();
  stderr.writeln('    enabled=${state.enabled}');

  stderr.writeln('[6] fetching HTTP profile');
  final profile = await s.vm.getHttpProfile();
  stderr.writeln('    requests: ${profile.requests.length}');
  for (final r in profile.requests.take(10)) {
    stderr.writeln('    - ${r.method} ${r.uri} (status=${r.response?.statusCode})');
  }

  await s.detach();
  stderr.writeln('done.');
}
