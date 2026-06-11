import 'package:flutter_network_mcp/src/tools/network_attach.dart';
import 'package:test/test.dart';

/// Issue #14: `appNameContains` resolved against only the default DTD, so an
/// app that network_status clearly listed (but owned by another DTD) failed
/// to attach. These pin the cross-DTD matcher.
void main() {
  final dtdA = Uri.parse('ws://127.0.0.1:55580/jPg2KTYi1Ao=');
  final dtdB = Uri.parse('ws://127.0.0.1:59639/EvI_lcFkbkg=');

  // Two sims, each on its own DTD — the exact shape from the bug report.
  final apps = <DtdAppCandidate>[
    (
      name: 'Kind: Flutter - Device: iPhone 16 Pro - Package: roqquapp',
      uri: 'ws://127.0.0.1:55581/5NPtiYDWars=/ws',
      dtdUri: dtdA,
    ),
    (
      name: 'Kind: Flutter - Device: iPhone 16 - Package: roqquapp',
      uri: 'ws://127.0.0.1:59640/2MhmFwcPryM=/ws',
      dtdUri: dtdB,
    ),
  ];

  test('matches an app owned by a non-default DTD', () {
    final m = matchAppsAcrossDtds(apps, 'iPhone 16 Pro');
    expect(m, hasLength(1));
    expect(m.single.uri, 'ws://127.0.0.1:55581/5NPtiYDWars=/ws');
    expect(m.single.dtdUri, dtdA);
  });

  test('is case-insensitive', () {
    expect(matchAppsAcrossDtds(apps, 'iphone 16 pro'), hasLength(1));
  });

  test('returns empty when nothing matches', () {
    expect(matchAppsAcrossDtds(apps, 'Android'), isEmpty);
  });

  test('ambiguous substring returns every match (caller errors on >1)', () {
    // "iPhone 16" is a substring of BOTH names.
    final m = matchAppsAcrossDtds(apps, 'iPhone 16');
    expect(m, hasLength(2));
  });

  test('null app names do not throw', () {
    final withNull = <DtdAppCandidate>[
      (name: null, uri: 'ws://x/ws', dtdUri: dtdA),
      ...apps,
    ];
    expect(matchAppsAcrossDtds(withNull, 'roqquapp'), hasLength(2));
  });
}
