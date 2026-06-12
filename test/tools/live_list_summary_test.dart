import 'package:flutter_network_mcp/src/tools/network_list.dart';
import 'package:test/test.dart';

/// UX pass: network_list LIVE is cursor-incremental. The empty-but-captured
/// case must not read as "no traffic" (the trap found in live testing).
void main() {
  const scope = 'session 1 (live, sanga_mobile)';

  String s({
    int matched = 0,
    int scannedTotal = 0,
    bool cursorAdvanced = false,
    bool incremental = false,
  }) =>
      liveListSummary(
        matched: matched,
        scannedTotal: scannedTotal,
        cursorAdvanced: cursorAdvanced,
        incremental: incremental,
        scopeLabel: scope,
      );

  test('truly empty (no cursor) says "captured yet"', () {
    final out = s();
    expect(out, contains('No HTTP captured yet'));
    expect(out, isNot(contains('since:0')));
  });

  test('empty incremental read does NOT claim no traffic, points at since:0',
      () {
    final out = s(cursorAdvanced: true, incremental: true);
    expect(out, isNot(contains('captured yet')));
    expect(out, contains('No NEW HTTP'));
    expect(out, contains('since:0'));
    expect(out, contains('incremental'));
  });

  test('empty explicit-since read points at since:0 without "your last call"',
      () {
    final out = s(cursorAdvanced: true, incremental: false);
    expect(out, contains('since:0'));
    expect(out, isNot(contains('your last call')));
  });

  test('filters excluded everything is distinct from no-data', () {
    final out = s(scannedTotal: 6);
    expect(out, contains('6 request(s) scanned'));
    expect(out, contains('0 matched filters'));
  });

  test('results: incremental flag annotates "new since your last call"', () {
    expect(s(matched: 3, incremental: true),
        contains('new since your last call'));
    expect(s(matched: 3, incremental: false),
        isNot(contains('new since your last call')));
  });
}
