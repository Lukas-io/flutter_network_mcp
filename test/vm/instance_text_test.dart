import 'package:flutter_network_mcp/src/tools/logs_tail.dart';
import 'package:flutter_network_mcp/src/vm/instance_text.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';

final _long = 'x' * 600;

InstanceRef _str(String id, String preview, {bool cut = false, int? length}) =>
    InstanceRef(
      id: id,
      kind: InstanceKind.kString,
      identityHashCode: 0,
      classRef: ClassRef(id: 'c', name: 'String', library: null),
      valueAsString: preview,
      valueAsStringIsTruncated: cut,
      length: length,
    );

/// Expands `long`, answers toString for `err`, and has collected everything else.
class _Service implements VmService {
  @override
  Future<Obj> getObject(String isolateId, String objectId,
      {int? offset, int? count, String? idZoneId}) async {
    if (objectId != 'long') {
      throw SentinelException.parse('getObject', {'type': 'Sentinel', 'kind': 'Collected', 'valueAsString': '<collected>'});
    }
    return Instance(
      id: objectId,
      kind: InstanceKind.kString,
      identityHashCode: 0,
      classRef: ClassRef(id: 'c', name: 'String', library: null),
      valueAsString: _long,
    );
  }

  @override
  Future<Response> invoke(String isolateId, String targetId, String selector,
          List<String> argumentIds,
          {bool? disableBreakpoints, String? idZoneId}) async =>
      _str('s', 'Bad state: boom');

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('$i');
}

void main() {
  final service = _Service();

  test('#104: a message cut at the VM preview is refetched whole', () async {
    final ref = _str('long', 'x' * 128, cut: true, length: 600);
    expect(await instanceText(service, 'iso', ref), _long);
  });

  test('a non-string error is turned into its toString', () async {
    final err = InstanceRef(
      id: 'err',
      kind: InstanceKind.kPlainInstance,
      identityHashCode: 0,
      classRef: ClassRef(id: 'c', name: 'StateError', library: null),
    );
    expect(await instanceText(service, 'iso', err), 'Bad state: boom');
  });

  test('when the VM cannot expand it, the preview says how much was cut', () async {
    final ref = _str('gone', 'y' * 128, cut: true, length: 900);
    expect(await instanceText(service, 'iso', ref),
        '${'y' * 128}… [cut by the VM at 128 of 900 chars]');
  });

  test('truncateMessage never splits a surrogate pair', () {
    final t = truncateMessage('ab😀cd', 3);
    expect(t.message, 'ab');
    expect(t.truncated, isTrue);
    expect(t.totalLength, 6);
  });
}
