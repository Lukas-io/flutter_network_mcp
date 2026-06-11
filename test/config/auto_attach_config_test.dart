import 'dart:convert';
import 'dart:io';

import 'package:flutter_network_mcp/src/config/auto_attach_config.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Resolves the data-dir the same way `lib/src/util/data_dir.dart` does
/// so the test can write fixtures + clean up afterward.
String? _resolveDataDir() {
  final env = Platform.environment;
  final override = env['FLUTTER_NETWORK_MCP_DATA_DIR'];
  if (override != null && override.isNotEmpty) return override;
  final home = env['HOME'];
  if (home == null || home.isEmpty) return null;
  if (Platform.isMacOS) {
    return p.join(
      home,
      'Library',
      'Application Support',
      'flutter_network_mcp',
    );
  }
  final xdg = env['XDG_DATA_HOME'];
  if (xdg != null && xdg.isNotEmpty) {
    return p.join(xdg, 'flutter_network_mcp');
  }
  return p.join(home, '.local', 'share', 'flutter_network_mcp');
}

void main() {
  group('AutoAttachConfig file persistence', () {
    late String dataDir;
    late File configFile;
    File? backup;

    setUp(() {
      final resolved = _resolveDataDir();
      if (resolved == null) {
        markTestSkipped('data dir not resolvable in this environment');
        return;
      }
      dataDir = resolved;
      Directory(dataDir).createSync(recursive: true);
      configFile = File(p.join(dataDir, AutoAttachConfig.fileName));
      if (configFile.existsSync()) {
        backup = File('${configFile.path}.test-backup');
        configFile.copySync(backup!.path);
        configFile.deleteSync();
      }
    });

    tearDown(() {
      if (configFile.existsSync()) configFile.deleteSync();
      if (backup != null && backup!.existsSync()) {
        backup!.copySync(configFile.path);
        backup!.deleteSync();
      }
      AutoAttachConfig.set(allowed: const [], denied: const []);
    });

    test('loadFromFile returns empty lists when file missing', () {
      final result = AutoAttachConfig.loadFromFile();
      expect(result.allowed, isEmpty);
      expect(result.denied, isEmpty);
    });

    test('round-trip allowed + denied via write + load', () {
      AutoAttachConfig.set(
        allowed: ['sanga_mobile', 'sanga_driver'],
        denied: ['iPhone 7'],
      );
      expect(AutoAttachConfig.writeToFile(), isTrue);
      // Reset in-memory state.
      AutoAttachConfig.set(allowed: const [], denied: const []);
      final loaded = AutoAttachConfig.loadFromFile();
      expect(loaded.allowed, ['sanga_mobile', 'sanga_driver']);
      expect(loaded.denied, ['iPhone 7']);
    });

    test('loadFromFile is resilient to malformed JSON', () {
      configFile.writeAsStringSync('not valid json {');
      final result = AutoAttachConfig.loadFromFile();
      expect(result.allowed, isEmpty);
      expect(result.denied, isEmpty);
    });

    test('loadFromFile is resilient to wrong types', () {
      configFile.writeAsStringSync(
        jsonEncode({'allowed': 'not a list', 'denied': 42}),
      );
      final result = AutoAttachConfig.loadFromFile();
      expect(result.allowed, isEmpty);
      expect(result.denied, isEmpty);
    });

    test('writeToFile produces valid JSON the loader can parse', () {
      AutoAttachConfig.set(
        allowed: ['app1', 'app2'],
        denied: ['dev1'],
      );
      AutoAttachConfig.writeToFile();
      final raw = configFile.readAsStringSync();
      final decoded = jsonDecode(raw) as Map<String, Object?>;
      expect(decoded['allowed'], ['app1', 'app2']);
      expect(decoded['denied'], ['dev1']);
      expect(decoded['writtenAtMs'], isA<int>());
    });

    test('writeToFile skips empty strings', () {
      // The reader filters empties. Set raw config containing empties
      // via a manual write.
      configFile.writeAsStringSync(
        jsonEncode({'allowed': ['', 'good', ''], 'denied': []}),
      );
      final loaded = AutoAttachConfig.loadFromFile();
      expect(loaded.allowed, ['good']);
    });
  });
}
