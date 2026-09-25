import 'dart:io';

import 'package:flutter_network_mcp/src/version.dart';
import 'package:test/test.dart';

import '../tool/release.dart';

void main() {
  test('pubspec.yaml and packageVersion agree', () {
    expect(currentVersion(), packageVersion);
    expect(File('pubspec.yaml').readAsStringSync(), contains('version: $packageVersion'));
  });

  const changelog = '# Changelog\n\n## [Unreleased]\n\n### Fixed\n\n- A thing.\n\n## [0.1.0] - 2026-01-01\n\n- Old.\n';

  test('prepare moves Unreleased entries under a dated heading', () {
    final out = datedChangelog(changelog, '0.2.0', DateTime(2026, 9, 25))!;
    expect(out, contains('## [Unreleased]\n\n## [0.2.0] - 2026-09-25\n\n### Fixed\n\n- A thing.'));
    expect(changelogSection(out, '0.2.0'), '### Fixed\n\n- A thing.\n');
    expect(changelogSection(out, '0.1.0'), '- Old.\n');
  });

  test('prepare refuses an empty Unreleased section', () {
    expect(datedChangelog('## [Unreleased]\n\n## [0.1.0] - x\n- Old.\n', '0.2.0', DateTime(2026)), isNull);
  });

  test('versions compare as numbers, not text', () {
    expect(isNewer('0.11.0', '0.10.0'), isTrue);
    expect(isNewer('0.10.0', '0.9.18'), isTrue);
    expect(isNewer('0.10.0', '0.10.0'), isFalse);
  });

  test('the notes command finds sections written with an em dash too', () {
    expect(changelogSection('## [0.10.0] — 2026-07-02\n\n- Shipped.\n', '0.10.0'), '- Shipped.\n');
  });
}
