import 'dart:io' as io;

import 'package:path/path.dart' as p;

/// Single source of truth for the running package version. Read by
/// `lib/src/server.dart` (Implementation), `bin/flutter_network_mcp.dart`
/// (UpdateCheck), and the docs. Must match the `version:` line in
/// `pubspec.yaml` — bump in both places at release time.
const String packageVersion = '0.9.16';

/// Commit SHA baked in at AOT-compile time by `flutter_network_mcp install`
/// via `-Dflutter_network_mcp_sha=<sha>`. Empty when running JIT (the
/// wrapper that ships from `pub global activate`).
const String _bakedSha = String.fromEnvironment(
  'flutter_network_mcp_sha',
);

String? _cachedRuntimeSha;
bool _runtimeShaResolved = false;

/// Returns the git commit SHA the running binary was built from. Sourced in
/// order: (1) baked-in `-D` constant set by `install`, (2) `git rev-parse
/// HEAD` against the activated source dir (works under JIT). Result cached
/// per process. Returns null on best-effort failure — the SHA is a
/// nice-to-have for the agent, not a load-bearing field.
String? currentCommitSha() {
  if (_bakedSha.isNotEmpty) return _bakedSha;
  if (_runtimeShaResolved) return _cachedRuntimeSha;
  _runtimeShaResolved = true;
  _cachedRuntimeSha = _readGitHead();
  return _cachedRuntimeSha;
}

/// True when running an AOT-compiled native binary (the result of
/// `flutter_network_mcp install`). False under the JIT snapshot wrapper.
const bool isAotBuild = bool.fromEnvironment('dart.vm.product');

String? _readGitHead() {
  try {
    final script = io.Platform.script.toFilePath();
    if (!script.endsWith('.dart')) return null;
    final sourceDir = p.dirname(p.dirname(script));
    final result = io.Process.runSync(
      'git',
      ['-C', sourceDir, 'rev-parse', 'HEAD'],
    );
    if (result.exitCode != 0) return null;
    final raw = (result.stdout as String?) ?? '';
    final sha = raw.trim();
    return sha.isEmpty ? null : sha;
  } catch (_) {
    return null;
  }
}
