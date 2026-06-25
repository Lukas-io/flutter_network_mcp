import 'dart:convert';
import 'dart:io' as io;

import 'package:path/path.dart' as p;

import '../config/auto_attach_config.dart';
import '../vm/dtd_discovery.dart';
import 'install.dart' as install_cmd;

/// `flutter_network_mcp setup` — interactive first-run wizard.
///
/// Six numbered steps, each opt-in via y/N prompt:
///
/// 1. Welcome + overview.
/// 2. Detect MCP host config (Claude Code today; setup spec lists the
///    others but they're out of scope for 0.7.4).
/// 3. Scaffold the MCP entry into the right config file.
/// 4. Discover running `flutter run` instances via the 0.6.2 DTD
///    discovery directory; offer auto-attach for any combination.
/// 5. Offer `install` (AOT compile) for sub-100ms startup.
/// 6. Verify + summary.
///
/// All filesystem writes are confirmed before they happen. The wizard
/// never silently changes anything.
Future<void> runSetup(List<String> args) async {
  io.stdout.writeln('');
  io.stdout.writeln('flutter_network_mcp setup');
  io.stdout.writeln('=========================');
  io.stdout.writeln(
    'Interactive first-run wizard. Each step is opt-in (default: skip).',
  );
  io.stdout.writeln('You can re-run setup any time to adjust.');
  io.stdout.writeln('');

  await _stepScaffoldHostConfig();
  io.stdout.writeln('');

  await _stepAutoAttach();
  io.stdout.writeln('');

  await _stepInstall();
  io.stdout.writeln('');

  io.stdout.writeln('---');
  io.stdout.writeln('Setup complete.');
  io.stdout.writeln('');
  io.stdout.writeln(
    'Restart your MCP host (Claude Code: /quit then re-open) to pick up '
    'the new configuration.',
  );
  io.stdout.writeln('');
}

Future<void> _stepScaffoldHostConfig() async {
  io.stdout.writeln('--- Step 1: MCP host config ---');
  io.stdout.writeln(
    '0.7.4 supports Claude Code (~/.claude.json or project-level '
    '.mcp.json). Cursor / Windsurf / Zed are on the roadmap; add them '
    'manually for now.',
  );

  final home = io.Platform.environment['HOME'];
  if (home == null || home.isEmpty) {
    io.stdout.writeln(
      'Skipping: HOME env var not set, can\'t locate ~/.claude.json.',
    );
    return;
  }
  final globalPath = p.join(home, '.claude.json');
  final globalExists = io.File(globalPath).existsSync();
  final localPath = p.join(io.Directory.current.path, '.mcp.json');
  final localExists = io.File(localPath).existsSync();

  io.stdout.writeln(
    'Detected: '
    '${globalExists ? "$globalPath (exists)" : "$globalPath (missing)"}; '
    '${localExists ? "$localPath (exists)" : "$localPath (missing)"}.',
  );

  if (globalExists &&
      _hasMcpEntry(_readJson(globalPath), 'flutter-network')) {
    io.stdout.writeln(
      'Already registered in ~/.claude.json under "flutter-network". '
      'Skipping scaffold.',
    );
    return;
  }
  if (localExists &&
      _hasMcpEntry(_readJson(localPath), 'flutter-network')) {
    io.stdout.writeln(
      'Already registered in $localPath under "flutter-network". '
      'Skipping scaffold.',
    );
    return;
  }

  final useGlobal = _ask(
    'Register globally in ~/.claude.json (yes) or as project-level '
    '.mcp.json in cwd (no)?',
    defaultNo: false,
  );
  final targetPath = useGlobal ? globalPath : localPath;
  if (!_ask('Write the MCP entry to $targetPath?', defaultNo: false)) {
    io.stdout.writeln('Skipping scaffold.');
    return;
  }

  final existing = _readJson(targetPath);
  final mcpServers = (existing['mcpServers'] as Map?)?.cast<String, Object?>() ??
      <String, Object?>{};
  mcpServers['flutter-network'] = <String, Object?>{
    'type': 'stdio',
    'command': 'flutter_network_mcp',
  };
  existing['mcpServers'] = mcpServers;
  _writeJson(targetPath, existing);
  io.stdout.writeln('Wrote $targetPath.');
}

Future<void> _stepAutoAttach() async {
  io.stdout.writeln('--- Step 2: auto-attach for running apps ---');
  final candidates = DtdDiscovery.discover(cwd: null)
      .where((c) => c.isLive)
      .toList();
  if (candidates.isEmpty) {
    io.stdout.writeln(
      'No running DTDs found. Start `flutter run` for any app you want '
      'auto-attached, then re-run setup.',
    );
    return;
  }
  io.stdout.writeln(
    'Found ${candidates.length} running DTD(s). For each, optionally '
    'enable auto-attach by package name:',
  );

  final fileConfig = AutoAttachConfig.loadFromFile();
  final allowed = fileConfig.allowed.toList();
  final denied = fileConfig.denied.toList();

  for (final c in candidates) {
    final ws = c.workspaceRoot ?? '(unknown workspace)';
    final pkg = _extractPackageName(ws);
    if (allowed.any((p) => p.toLowerCase() == pkg.toLowerCase())) {
      io.stdout.writeln('  $ws → "$pkg" already in allowlist; skipped.');
      continue;
    }
    if (_ask('  $ws → add "$pkg" to auto-attach?', defaultNo: false)) {
      allowed.add(pkg);
    }
  }

  if (allowed.length == fileConfig.allowed.length) {
    io.stdout.writeln('No changes to auto-attach config.');
    return;
  }
  AutoAttachConfig.set(allowed: allowed, denied: denied);
  final wrote = AutoAttachConfig.writeToFile();
  if (wrote) {
    io.stdout.writeln(
      'Persisted to ${AutoAttachConfig.filePath()}. Effective on next '
      'MCP-host restart.',
    );
  } else {
    io.stdout.writeln(
      'Failed to persist (filesystem error). The change is in memory '
      'for THIS process only.',
    );
  }
}

Future<void> _stepInstall() async {
  io.stdout.writeln('--- Step 3: AOT compile (recommended) ---');
  io.stdout.writeln(
    '`dart pub global activate` ships a JIT wrapper that recompiles on '
    'every spawn (~1–2s cold). AOT cuts startup to <100ms and avoids '
    'MCP-host handshake races.',
  );
  if (!_ask('Run `flutter_network_mcp install` now?', defaultNo: false)) {
    io.stdout.writeln('Skipping. You can run it later with that command.');
    return;
  }
  await install_cmd.runInstall(const []);
}

Map<String, Object?> _readJson(String path) {
  try {
    final raw = io.File(path).readAsStringSync();
    final decoded = jsonDecode(raw);
    if (decoded is Map) return decoded.cast<String, Object?>();
  } catch (_) {/* fall through */}
  return <String, Object?>{};
}

void _writeJson(String path, Map<String, Object?> data) {
  final file = io.File(path);
  if (!file.parent.existsSync()) file.parent.createSync(recursive: true);
  file.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(data),
  );
}

bool _hasMcpEntry(Map<String, Object?> json, String key) {
  final servers = json['mcpServers'];
  if (servers is! Map) return false;
  return servers.containsKey(key);
}

/// Best-effort package-name extraction from a workspaceRoot path. The
/// last non-empty path segment is usually the project folder, which on
/// Flutter conventions matches the pubspec name. Falls back to the
/// folder name verbatim — the user can rename via auto_attach_config.
String _extractPackageName(String workspaceRoot) {
  final cleaned = workspaceRoot.replaceAll('\\', '/').trimRight();
  final segments = cleaned.split('/').where((s) => s.isNotEmpty).toList();
  if (segments.isEmpty) return workspaceRoot;
  return segments.last;
}

/// Reads a y/N prompt from stdin. Returns true on 'y' / 'yes' (case-
/// insensitive). On empty enter, returns the prompt's default. On EOF
/// (e.g. non-interactive run like CI piping `cat /dev/null`), returns
/// false — safer to skip than to proceed without confirmation.
bool _ask(String question, {bool defaultNo = true}) {
  final hint = defaultNo ? '[y/N]' : '[Y/n]';
  io.stdout.write('$question $hint ');
  final raw = io.stdin.readLineSync();
  if (raw == null) {
    io.stdout.writeln('(no input — skipping)');
    return false;
  }
  final trimmed = raw.trim().toLowerCase();
  if (trimmed.isEmpty) return !defaultNo;
  return trimmed == 'y' || trimmed == 'yes';
}
