import 'dart:io';

import 'package:flutter_network_mcp/src/install/install.dart';
import 'package:flutter_network_mcp/src/install/update.dart';
import 'package:flutter_network_mcp/src/util/legacy_install.dart';
import 'package:test/test.dart';

void main() {
  group('detectLegacyUse', () {
    test('a clean glint_network setup has no notice', () {
      final use = detectLegacyUse(package: 'glint_network', env: const {}, parentCommand: 'sh /h/.pub-cache/bin/glint_network');
      expect(use.any, isFalse);
      expect(use.notice, isNull);
    });

    test('the bridge package asks for an update to the glint repository', () {
      final use = detectLegacyUse(package: 'flutter_network_mcp', env: const {}, parentCommand: '');
      expect(use.notice, contains('run `flutter_network_mcp update`'));
      expect(use.notice, contains(legacySunset));
    });

    test('pub\'s flutter_network_mcp wrapper is recognised as the old command', () {
      final use = detectLegacyUse(env: const {}, parentCommand: 'sh /Users/me/.pub-cache/bin/flutter_network_mcp --auto-attach=x');
      expect(use.oldCommand, isTrue);
      expect(use.notice, contains('rename the server entry to "glint-network"'));
    });

    test('the native shim marks the old command through the environment', () {
      expect(detectLegacyUse(env: const {launchedAsEnv: 'flutter_network_mcp'}, parentCommand: '').oldCommand, isTrue);
    });

    test('old env vars are listed with their new names', () {
      final use = detectLegacyUse(env: const {'FLUTTER_NETWORK_MCP_TELEMETRY': 'on'}, parentCommand: '');
      expect(use.notice, contains('rename FLUTTER_NETWORK_MCP_TELEMETRY to GLINT_NETWORK_TELEMETRY'));
    });

    test('a path merely containing the old name is not the old command', () {
      expect(launchedByLegacyCommand('dart run /src/flutter_network_mcp_fork/bin/glint_network.dart'), isFalse);
    });
  });

  group('newestPubCacheSource', () {
    late Directory git;
    setUp(() => git = Directory.systemTemp.createTempSync('pubgit'));
    tearDown(() => git.deleteSync(recursive: true));

    File entry(String path, DateTime modified) =>
        File('${git.path}/$path')
          ..createSync(recursive: true)
          ..setLastModifiedSync(modified);

    test('finds the glint repository layout and the old root layout, newest first', () {
      final old = entry('flutter_network_mcp-aaa/bin/flutter_network_mcp.dart', DateTime(2026, 9));
      final current = entry('glint-bbb/packages/glint_network/bin/glint_network.dart', DateTime(2026, 10));
      entry('glint-ccc/packages/glint_mcp/bin/glint.dart', DateTime(2026, 11));
      expect(newestPubCacheSource(git), current.path);
      current.setLastModifiedSync(DateTime(2026, 8));
      expect(newestPubCacheSource(git), old.path);
    });
  });

  test('the shim for the old command tells the server how it was started', () {
    expect(execShim('/aot/glint_network'), '#!/bin/sh\nexec "/aot/glint_network" "\$@"\n');
    expect(execShim('/aot/glint_network', launchedAs: 'flutter_network_mcp'),
        '#!/bin/sh\n$launchedAsEnv=flutter_network_mcp exec "/aot/glint_network" "\$@"\n');
  });

  test('update takes over commands the old package still owns', () {
    expect(activateArgs('https://github.com/Lukas-io/glint.git'),
        containsAllInOrder(['--git-path', 'packages/glint_network', '--overwrite']));
  });
}
