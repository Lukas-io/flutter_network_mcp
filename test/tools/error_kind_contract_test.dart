import 'package:flutter_network_mcp/src/tools/error_kind.dart';
import 'package:flutter_network_mcp/src/tools/result.dart';
import 'package:test/test.dart';

/// The agent-intuitive response contract: errors carry a stable, branchable
/// `errorKind`; degraded (fallback) results are uniformly flagged.
void main() {
  group('errorResult emits errorKind', () {
    test('a kind is rendered as its stable wire string', () {
      final r = errorResult('boom', kind: ErrorKind.unresponsiveVm);
      final sc = r.structuredContent!;
      expect(r.isError, isTrue);
      expect(sc['error'], 'boom');
      expect(sc['errorKind'], 'unresponsive_vm');
    });

    test('no kind -> no errorKind field (back-compat)', () {
      final r = errorResult('boom');
      expect(r.structuredContent!.containsKey('errorKind'), isFalse);
    });

    test('extra fields (schema, nextSteps) are merged alongside errorKind', () {
      final r = errorResult('bad sql',
          kind: ErrorKind.badQuery,
          extra: {
            'schema': {'sessions': ['id', 'app_name']},
            'nextSteps': ['fix it'],
          });
      final sc = r.structuredContent!;
      expect(sc['errorKind'], 'bad_query');
      expect((sc['schema'] as Map)['sessions'], ['id', 'app_name']);
      expect(sc['nextSteps'], ['fix it']);
    });

    test('every ErrorKind wire string is unique and snake_case', () {
      final wires = ErrorKind.values.map((k) => k.wire).toList();
      expect(wires.toSet().length, wires.length, reason: 'wires must be unique');
      for (final w in wires) {
        expect(w, matches(RegExp(r'^[a-z]+(_[a-z]+)*$')));
      }
    });
  });

  group('degradedResult', () {
    test('flags degraded:true and prepends the reason to warnings', () {
      final r = degradedResult(
        {
          'source': 'live-db-fallback',
          'count': 2,
          'warnings': ['pre-existing warning'],
        },
        reason: 'live read failed; returned DB snapshot',
      );
      final sc = r.structuredContent!;
      expect(r.isError, isFalse);
      expect(sc['degraded'], isTrue);
      expect(sc['source'], 'live-db-fallback');
      expect(sc['warnings'], [
        'live read failed; returned DB snapshot',
        'pre-existing warning',
      ]);
    });

    test('works when the payload has no prior warnings', () {
      final r = degradedResult({'source': 'live-db-fallback', 'count': 0},
          reason: 'fell back');
      expect(r.structuredContent!['warnings'], ['fell back']);
    });
  });

  // D3 (audit RC5/F26): a healthy VM answering "no such id" must classify as
  // not_found, not unresponsive_vm — the classifier is the shared decision.
  group('looksLikeVmIdMiss (D3 taxonomy)', () {
    test('VM id-lookup miss is recognized', () {
      expect(
          looksLikeVmIdMiss(
              'getHttpProfileRequest: (-32602) Invalid params\n'
              "Unable to find request with id: 'bogus'"),
          isTrue);
      expect(looksLikeVmIdMiss('Unable to find request with id: 42'), isTrue);
    });

    test('transport failures are NOT id misses', () {
      expect(looksLikeVmIdMiss('Service connection disposed'), isFalse);
      expect(looksLikeVmIdMiss('VmRpcTimeoutException(getHttpProfileRequest)'),
          isFalse);
      expect(looksLikeVmIdMiss(null), isFalse);
    });
  });
}
