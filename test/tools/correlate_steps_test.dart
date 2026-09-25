import 'package:flutter_network_mcp/src/tools/network_correlate.dart';
import 'package:test/test.dart';

void main() {
  Map<String, Object?> req(int sid, String id, int t) =>
      {'sessionId': sid, 'id': id, 'startTimeMs': t};

  test('the earlier request is named the originator, whatever the list order',
      () {
    final steps = pairInspectSteps({
      'spanMs': 300,
      'requests': [req(14, 'late', 1300), req(15, 'early', 1000)],
    });
    expect(steps.first, contains('sessionId:15 id:"early"'));
    expect(steps.first, contains('earlier request (300ms before its pair'));
    expect(steps.last, contains('sessionId:14 id:"late"'));
    expect(steps.last, contains('later request'));
  });

  test('simultaneous requests are not labelled originator or receiver', () {
    final steps = pairInspectSteps({
      'spanMs': 0,
      'requests': [req(14, 'a', 1000), req(15, 'b', 1000)],
    });
    expect(steps.join(' '), isNot(contains('originator')));
    expect(steps.first, contains('same start time'));
  });
}
