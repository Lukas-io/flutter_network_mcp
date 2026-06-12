import 'package:flutter_network_mcp/src/session_migrator.dart';
import 'package:test/test.dart';

/// Issue #16: the pure decision core that picks which attached sessions to
/// reattach across a hot restart. The watcher does the IO; this proves it
/// only migrates when there is exactly one safe target.
void main() {
  // DTD app-name shape appSessionIdentity understands.
  String app(String pkg, {String device = 'iPhone 17'}) =>
      'Flutter - Device: $device - Package: $pkg';

  ({int id, String uri, String? appName}) sess(
    int id,
    String uri,
    String? appName,
  ) =>
      (id: id, uri: uri, appName: appName);

  test('a session whose URI is still live is left alone', () {
    final plans = planMigrations(
      attached: [sess(1, 'ws://a', app('sanga_mobile'))],
      liveByUri: {'ws://a': app('sanga_mobile')},
    );
    expect(plans, isEmpty);
  });

  test('dead session with one same-identity live URI migrates', () {
    final plans = planMigrations(
      attached: [sess(7, 'ws://old', app('sanga_mobile'))],
      liveByUri: {'ws://new': app('sanga_mobile')},
    );
    expect(plans, hasLength(1));
    expect(plans.single.priorSessionId, 7);
    expect(plans.single.priorUri, 'ws://old');
    expect(plans.single.newUri, 'ws://new');
  });

  test('dead session with no live replacement is not migrated', () {
    final plans = planMigrations(
      attached: [sess(1, 'ws://old', app('sanga_mobile'))],
      liveByUri: {'ws://other': app('aetrust')},
    );
    expect(plans, isEmpty);
  });

  test('two same-identity candidates are ambiguous, so no migration', () {
    final plans = planMigrations(
      attached: [sess(1, 'ws://old', app('sanga_mobile'))],
      liveByUri: {
        'ws://new1': app('sanga_mobile'),
        'ws://new2': app('sanga_mobile'),
      },
    );
    expect(plans, isEmpty);
  });

  test('a candidate that is already attached is excluded', () {
    final plans = planMigrations(
      // session 2 is alive at ws://new (same app on a second device-less run)
      attached: [
        sess(1, 'ws://old', app('sanga_mobile')),
        sess(2, 'ws://new', app('sanga_mobile')),
      ],
      liveByUri: {'ws://new': app('sanga_mobile')},
    );
    // ws://new is the only same-identity live URI but it's already attached,
    // so session 1 has no free candidate.
    expect(plans, isEmpty);
  });

  test('different-identity live URIs never match', () {
    final plans = planMigrations(
      attached: [sess(1, 'ws://old', app('sanga_mobile'))],
      liveByUri: {'ws://new': app('sanga_mobile', device: 'Pixel 7')},
    );
    expect(plans, isEmpty, reason: 'device differs, so identity differs');
  });

  test('two dead sessions sharing one candidate: only the first claims it', () {
    final plans = planMigrations(
      attached: [
        sess(1, 'ws://old1', app('sanga_mobile')),
        sess(2, 'ws://old2', app('sanga_mobile')),
      ],
      liveByUri: {'ws://new': app('sanga_mobile')},
    );
    expect(plans, hasLength(1));
    expect(plans.single.priorSessionId, 1);
    expect(plans.single.newUri, 'ws://new');
  });

  test('null / unparseable identity is skipped', () {
    final plans = planMigrations(
      attached: [sess(1, 'ws://old', null), sess(2, 'ws://old2', '')],
      liveByUri: {'ws://new': app('sanga_mobile')},
    );
    expect(plans, isEmpty);
  });

  test('independent apps migrate independently in one pass', () {
    final plans = planMigrations(
      attached: [
        sess(1, 'ws://a-old', app('sanga_mobile')),
        sess(2, 'ws://b-old', app('aetrust')),
      ],
      liveByUri: {
        'ws://a-new': app('sanga_mobile'),
        'ws://b-new': app('aetrust'),
      },
    );
    expect(plans, hasLength(2));
    expect(
      {for (final p in plans) p.priorSessionId: p.newUri},
      {1: 'ws://a-new', 2: 'ws://b-new'},
    );
  });
}
