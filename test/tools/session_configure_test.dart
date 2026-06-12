import 'package:dart_mcp/server.dart';
import 'package:flutter_network_mcp/src/config/session_filters.dart';
import 'package:flutter_network_mcp/src/tools/session_configure.dart';
import 'package:test/test.dart';

/// Issue #18: process-wide sticky default filters that logs_tail / network_list
/// inherit. These exercise the config state + the session_configure handler's
/// set / unset / clear semantics.
void main() {
  setUp(SessionFilters.resetForTest);

  CallToolRequest req([Map<String, Object?>? args]) =>
      CallToolRequest(name: 'session_configure', arguments: args);

  group('SessionFilters state', () {
    test('starts empty', () {
      expect(SessionFilters.instance.isEmpty, isTrue);
      expect(SessionFilters.instance.toBlock(), isEmpty);
    });

    test('clear() resets every field', () {
      final sf = SessionFilters.instance
        ..levelMin = 1000
        ..messageContains = ['a']
        ..statusMin = 400;
      expect(sf.isEmpty, isFalse);
      sf.clear();
      expect(sf.isEmpty, isTrue);
    });

    test('empty messageContains/method do not count as set', () {
      final sf = SessionFilters.instance
        ..messageContains = []
        ..method = [];
      expect(sf.isEmpty, isTrue);
      expect(sf.toBlock(), isEmpty);
    });
  });

  group('session_configure handler', () {
    test('sets log + http defaults', () async {
      await sessionConfigure(req({
        'levelMin': 1000,
        'messageContains': ['[EventTracker]', 'KycTier'],
        'statusMin': 400,
      }));
      final sf = SessionFilters.instance;
      expect(sf.levelMin, 1000);
      expect(sf.messageContains, ['[EventTracker]', 'KycTier']);
      expect(sf.statusMin, 400);
    });

    test('messageContains accepts a bare string too', () async {
      await sessionConfigure(req({'messageContains': 'solo'}));
      expect(SessionFilters.instance.messageContains, ['solo']);
    });

    test('absent keys leave existing defaults unchanged', () async {
      await sessionConfigure(req({'levelMin': 800}));
      await sessionConfigure(req({'statusMin': 500}));
      final sf = SessionFilters.instance;
      expect(sf.levelMin, 800, reason: 'untouched by the second call');
      expect(sf.statusMin, 500);
    });

    test('present null unsets just that field', () async {
      await sessionConfigure(req({'levelMin': 800, 'statusMin': 500}));
      await sessionConfigure(req({'levelMin': null}));
      final sf = SessionFilters.instance;
      expect(sf.levelMin, isNull);
      expect(sf.statusMin, 500, reason: 'other defaults survive');
    });

    test('clear:true resets all, applied before same-call sets', () async {
      await sessionConfigure(req({'levelMin': 800, 'hostContains': 'api'}));
      await sessionConfigure(req({'clear': true, 'levelMin': 1200}));
      final sf = SessionFilters.instance;
      expect(sf.hostContains, isNull);
      expect(sf.levelMin, 1200, reason: 'set after the clear in the same call');
    });

    test('result echoes the active defaults block', () async {
      final res = await sessionConfigure(req({'statusMin': 400}));
      final sc = res.structuredContent!;
      expect((sc['defaults'] as Map)['statusMin'], 400);
      expect(sc['summary'], contains('statusMin'));
    });

    test('no args returns current state without mutating', () async {
      await sessionConfigure(req({'levelMin': 900}));
      final res = await sessionConfigure(req());
      expect(SessionFilters.instance.levelMin, 900);
      expect((res.structuredContent!['defaults'] as Map)['levelMin'], 900);
    });
  });
}
