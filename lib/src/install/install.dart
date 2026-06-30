import 'dart:io' as io;

import 'package:path/path.dart' as p;

import '../util/data_dir.dart';

/// `flutter_network_mcp install` subcommand: AOT-builds this package's
/// entrypoint via `dart build cli` (a relocatable bundle, since Dart 3.12's
/// `dart compile exe` rejects packages with native build hooks like sqlite3)
/// and points the JIT wrapper that `dart pub global activate` ships at the
/// resulting native binary via an exec shim.
///
/// Why: the standard `pub global activate -s git URL` install ships a snapshot
/// wrapper that re-runs `pub get` + recompiles on every spawn. Cold start is
/// 1–2 seconds, which the MCP host's JSON-RPC handshake can race and mark
/// the server as "Failed to connect" on first attach. AOT cuts startup to
/// <100ms, no recompile, no flicker.
///
/// Resolves the source via `Platform.script.toFilePath()` — under the JIT
/// wrapper that points at the activated source dir
/// (`~/.pub-cache/git/flutter_network_mcp-<hash>/bin/flutter_network_mcp.dart`).
/// Resolves the output via `Platform.executable` — under the wrapper that's
/// the dart binary, so we instead derive the install target from the wrapper
/// script's path (which IS the install location).
///
/// On success, writes a marker file `<data-dir>/.compiled` so the future
/// `update` subcommand knows the user prefers an AOT binary and should
/// re-compile after each `pub global activate`.
Future<void> runInstall(List<String> args) async {
  final source = _resolveSourcePath();
  if (source == null) {
    io.stderr.writeln(
      'flutter_network_mcp install: could not locate the package source. '
      'Platform.script="${io.Platform.script}". Run from inside the activated '
      'flutter_network_mcp install, or run `dart pub global activate -s git '
      'https://github.com/Lukas-io/flutter_network_mcp.git` first.',
    );
    io.exitCode = 70;
    return;
  }

  final output = _resolveOutputPath();
  if (output == null) {
    io.stderr.writeln(
      'flutter_network_mcp install: could not resolve install output path. '
      'Set PUB_CACHE or HOME and retry.',
    );
    io.exitCode = 70;
    return;
  }

  // Dart 3.12 made `dart compile exe` reject packages with native build hooks
  // (sqlite3 ships them), so we build a relocatable CLI bundle with
  // `dart build cli` instead. That produces `<bundleDir>/bundle/bin/<exe>` plus
  // a sibling `lib/` (libsqlite3.dylib) the exe finds via its own rpath. We
  // then point the install target [output] at it with a tiny exec shim, so the
  // MCP host config (which runs [output]) is unchanged.
  final bundleDir = p.join(p.dirname(output), '.flutter_network_mcp_aot');
  final exePath = p.join(bundleDir, 'bundle', 'bin', 'flutter_network_mcp');

  io.stderr.writeln(
    'flutter_network_mcp install: building $source\n'
    '                          to $bundleDir\n'
    '(this takes ~10–20s; the resulting binary starts in <100ms).',
  );

  try {
    final old = io.Directory(bundleDir);
    if (old.existsSync()) old.deleteSync(recursive: true);
  } catch (_) {/* best-effort clean rebuild */}

  final io.Process build;
  try {
    build = await io.Process.start(
      'dart',
      ['build', 'cli', '-t', source, '-o', bundleDir],
      mode: io.ProcessStartMode.inheritStdio,
    );
  } on io.ProcessException catch (e) {
    io.stderr.writeln(
      'flutter_network_mcp install: failed to spawn `dart` (${e.message}). '
      'Is the Dart SDK on your PATH? Install from https://dart.dev/get-dart, '
      'verify with `which dart`, then retry.',
    );
    io.exitCode = 127;
    return;
  }
  final exitCode = await build.exitCode;
  if (exitCode != 0) {
    io.stderr.writeln(
      'flutter_network_mcp install: dart build cli exited $exitCode. '
      'See the dart output above. The JIT wrapper at $output is unchanged.',
    );
    io.exitCode = exitCode;
    return;
  }
  if (!io.File(exePath).existsSync()) {
    io.stderr.writeln(
      'flutter_network_mcp install: build succeeded but the expected binary '
      'is missing at $exePath. The JIT wrapper at $output is unchanged.',
    );
    io.exitCode = 70;
    return;
  }

  // Replace the install target with an exec shim at the bundle binary.
  try {
    io.File(output).writeAsStringSync('#!/bin/sh\nexec "$exePath" "\$@"\n');
    await io.Process.run('chmod', ['0755', output]);
  } catch (e) {
    io.stderr.writeln(
      'flutter_network_mcp install: built the binary but could not write the '
      'shim at $output ($e). Point your MCP host directly at:\n  $exePath',
    );
    io.exitCode = 70;
    return;
  }

  _writeCompiledMarker();

  io.stderr.writeln(
    'flutter_network_mcp install: done. Restart your MCP host to pick up '
    'the native binary (sub-100ms startup, no more handshake races).',
  );
}

/// Resolves the path to `bin/flutter_network_mcp.dart` inside the currently-
/// running install. Under the JIT wrapper, `Platform.script` points at the
/// activated source file directly. Under an already-compiled AOT binary
/// we still want to re-compile from the same source location — derived
/// via the pub-cache structure (`<pub_cache>/git/flutter_network_mcp-*/bin/
/// flutter_network_mcp.dart`).
String? _resolveSourcePath() {
  final script = io.Platform.script.toFilePath();
  if (script.endsWith('.dart') && io.File(script).existsSync()) {
    return script;
  }

  final cache = _pubCacheDir();
  if (cache == null) return null;
  final gitDir = io.Directory(p.join(cache, 'git'));
  if (!gitDir.existsSync()) return null;
  io.FileSystemEntity? newest;
  DateTime newestStamp = DateTime.fromMillisecondsSinceEpoch(0);
  for (final entity in gitDir.listSync()) {
    if (entity is! io.Directory) continue;
    if (!p.basename(entity.path).startsWith('flutter_network_mcp')) continue;
    final candidate = io.File(
      p.join(entity.path, 'bin', 'flutter_network_mcp.dart'),
    );
    if (!candidate.existsSync()) continue;
    final stamp = candidate.lastModifiedSync();
    if (stamp.isAfter(newestStamp)) {
      newestStamp = stamp;
      newest = candidate;
    }
  }
  return newest?.path;
}

/// Resolves the install target — the path the JIT wrapper currently
/// occupies, which we're about to overwrite with a native binary.
String? _resolveOutputPath() {
  final cache = _pubCacheDir();
  if (cache == null) return null;
  final binName = io.Platform.isWindows
      ? 'flutter_network_mcp.bat'
      : 'flutter_network_mcp';
  return p.join(cache, 'bin', binName);
}

/// Resolves `$PUB_CACHE`, falling back to `$HOME/.pub-cache` on POSIX or
/// `$APPDATA/Pub/Cache` on Windows. Matches the dart-sdk default.
String? _pubCacheDir() {
  final env = io.Platform.environment;
  final override = env['PUB_CACHE'];
  if (override != null && override.isNotEmpty) return override;
  if (io.Platform.isWindows) {
    final appData = env['APPDATA'];
    if (appData == null || appData.isEmpty) return null;
    return p.join(appData, 'Pub', 'Cache');
  }
  final home = env['HOME'];
  if (home == null || home.isEmpty) return null;
  return p.join(home, '.pub-cache');
}

/// Writes `<data-dir>/.compiled` (one-line ISO timestamp). Used by the
/// `update` subcommand to know the user prefers an AOT binary after the
/// next `pub global activate`. Errors are silent — the marker is a hint,
/// not a hard requirement.
void _writeCompiledMarker() {
  try {
    final dir = _resolveDataDir();
    if (dir == null) return;
    final dirHandle = io.Directory(dir);
    if (!dirHandle.existsSync()) {
      dirHandle.createSync(recursive: true);
    }
    io.File(p.join(dir, '.compiled')).writeAsStringSync(
      DateTime.now().toUtc().toIso8601String(),
    );
  } catch (_) {/* silent — marker is best-effort */}
}

/// Returns the canonical data-dir path. Delegates to the shared util in
/// `lib/src/util/data_dir.dart` so install + telemetry + DB all agree on
/// where the user's state lives.
String? _resolveDataDir() => resolveCandidateDataDir();

/// Public for the `update` subcommand: returns true iff the user previously
/// ran `install` (so update should re-compile after re-activating).
bool wantsAotAfterUpdate() {
  final dir = _resolveDataDir();
  if (dir == null) return false;
  return io.File(p.join(dir, '.compiled')).existsSync();
}
