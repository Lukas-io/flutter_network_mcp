import 'package:flutter_network_mcp/src/vm/log_stream.dart';
import 'package:test/test.dart';

void main() {
  test('a line printed twice in one millisecond keeps two keys; another process gets the same two', () {
    final here = OccurrenceCounter();
    final elsewhere = OccurrenceCounter();
    const line = 'stdout:iso:1700000000000:abc';
    final mine = [here.key(line), here.key(line)];
    final theirs = [elsewhere.key(line), elsewhere.key(line)];
    expect(mine, ['$line:0', '$line:1']);
    expect(theirs, mine);
  });
}
