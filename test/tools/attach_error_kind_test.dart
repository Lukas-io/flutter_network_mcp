import 'dart:async';
import 'dart:io';

import 'package:dart_mcp/server.dart';
import 'package:flutter_network_mcp/src/tools/error_kind.dart';
import 'package:flutter_network_mcp/src/tools/network_attach.dart';
import 'package:flutter_network_mcp/src/util/scope.dart';
import 'package:flutter_network_mcp/src/vm/vm_client.dart';
import 'package:test/test.dart';

void main() {
  group('network_attach errors carry errorKind', () {
    test('no DTD URI configured is bad_argument', () async {
      final r = await networkAttach(
        CallToolRequest(name: 'network_attach', arguments: const {}),
        null,
      );
      expect(r.isError, isTrue);
      expect(r.structuredContent!['errorKind'], 'bad_argument');
      expect(r.structuredContent!['nextSteps'], isNotEmpty);
    });

    test('an unreachable VM service is unresponsive_vm', () async {
      final r = await networkAttach(
        CallToolRequest(
          name: 'network_attach',
          arguments: const {'vmServiceUri': 'http://127.0.0.1:1/nope=/'},
        ),
        null,
      );
      expect(r.isError, isTrue);
      expect(r.structuredContent!['error'], startsWith('Attach failed'));
      expect(r.structuredContent!['errorKind'], 'unresponsive_vm');
    });
  });

  group('attachFailureKind', () {
    test('connection and RPC failures are unresponsive_vm', () {
      expect(attachFailureKind(const SocketException('Connection refused')),
          ErrorKind.unresponsiveVm);
      expect(attachFailureKind(VmRpcTimeoutException('getVM', Duration.zero)),
          ErrorKind.unresponsiveVm);
      expect(attachFailureKind(TimeoutException('slow')),
          ErrorKind.unresponsiveVm);
      expect(
          attachFailureKind(StateError('VM service at x accepted the '
              'connection but did not respond to getVersion() within 5s.')),
          ErrorKind.unresponsiveVm);
    });

    test('a VM with no profilable isolate is not_found', () {
      expect(
          attachFailureKind(StateError(
              'No running isolate exposes dart:io HTTP profiling.')),
          ErrorKind.notFound);
    });

    test('a malformed URI is bad_argument; anything else internal', () {
      expect(attachFailureKind(const FormatException('bad uri')),
          ErrorKind.badArgument);
      expect(attachFailureKind(StateError('boom')), ErrorKind.internal);
    });
  });

  group('resolveScope errors carry errorKind', () {
    test('nothing attached or opened is no_session', () {
      final (scope, err) = resolveScope(const {});
      expect(scope, isNull);
      expect(err!.structuredContent!['errorKind'], 'no_session');
    });

    test('an appNameContains matching no attached session is no_session', () {
      final (scope, err) = resolveScope(const {'appNameContains': 'zzz'});
      expect(scope, isNull);
      expect(err!.structuredContent!['errorKind'], 'no_session');
    });
  });
}
