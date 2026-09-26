import 'dart:io' as io;

import 'package:path/path.dart' as p;

import '../util/data_dir.dart';
import '../util/network_env.dart';
import 'repo_layout.dart';
import '../util/legacy_install.dart';

/// `glint_network install` subcommand: AOT-builds this package's
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
/// (`~/.pub-cache/git/glint_network-<hash>/bin/glint_network.dart`).
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
      'glint_network install: could not locate the package source. '
      'Platform.script="${io.Platform.script}". Run from inside the activated '
      'glint_network install, or run `dart pub global activate -s git '
      'https://github.com/Lukas-io/glint.git --git-path $packageGitPath` first.',
    );
    io.exitCode = 70;
    return;
  }

  final outputs = _resolveOutputPaths();
  if (outputs.isEmpty) {
    io.stderr.writeln(
      'glint_network install: could not resolve install output path. '
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
  final output = outputs.first;
  final bundleDir = p.join(p.dirname(output), '.glint_network_aot');
  final exePath =
      p.join(bundleDir, 'bundle', 'bin', p.basenameWithoutExtension(source));

  io.stderr.writeln(
    'glint_network install: building $source\n'
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
      'glint_network install: failed to spawn `dart` (${e.message}). '
      'Is the Dart SDK on your PATH? Install from https://dart.dev/get-dart, '
      'verify with `which dart`, then retry.',
    );
    io.exitCode = 127;
    return;
  }
  final exitCode = await build.exitCode;
  if (exitCode != 0) {
    io.stderr.writeln(
      'glint_network install: dart build cli exited $exitCode. '
      'See the dart output above. The JIT wrapper at $output is unchanged.',
    );
    io.exitCode = exitCode;
    return;
  }
  if (!io.File(exePath).existsSync()) {
    io.stderr.writeln(
      'glint_network install: build succeeded but the expected binary '
      'is missing at $exePath. The JIT wrapper at $output is unchanged.',
    );
    io.exitCode = 70;
    return;
  }

  // Replace each install target with an exec shim at the bundle binary.
  try {
    for (final target in outputs) {
      final legacy = p.basenameWithoutExtension(target) == legacyName;
      io.File(target).writeAsStringSync(
          execShim(exePath, launchedAs: legacy ? legacyName : null));
      await io.Process.run('chmod', ['0755', target]);
    }
  } catch (e) {
    io.stderr.writeln(
      'glint_network install: built the binary but could not write the '
      'shim at $output ($e). Point your MCP host directly at:\n  $exePath',
    );
    io.exitCode = 70;
    return;
  }

  _writeCompiledMarker();

  io.stderr.writeln(
    'glint_network install: done. Restart your MCP host to pick up '
    'the native binary (sub-100ms startup, no more handshake races).',
  );
}

/// Resolves the path to `bin/glint_network.dart` inside the currently-
/// running install. Under the JIT wrapper, `Platform.script` points at the
/// activated source file directly. Under an already-compiled AOT binary
/// we still want to re-compile from the same source location — derived
/// via the pub-cache structure (`<pub_cache>/git/glint_network-*/bin/
/// glint_network.dart`).
String? _resolveSourcePath() {
  final script = io.Platform.script.toFilePath();
  if (script.endsWith('.dart') && io.File(script).existsSync()) {
    return script;
  }

  final cache = _pubCacheDir();
  if (cache == null) return null;
  final gitDir = io.Directory(p.join(cache, 'git'));
  if (!gitDir.existsSync()) return null;
  return newestPubCacheSource(gitDir);
}

/// The newest entry point pub has checked out under [gitDir]: `glint-<commit>/packages/glint_network/bin/glint_network.dart`, or the old repository's `flutter_network_mcp-<commit>/bin/flutter_network_mcp.dart`.
String? newestPubCacheSource(io.Directory gitDir) {
  io.File? newest;
  var newestStamp = DateTime.fromMillisecondsSinceEpoch(0);
  for (final entity in gitDir.listSync()) {
    if (entity is! io.Directory) continue;
    final name = p.basename(entity.path);
    final String candidatePath;
    if (name.startsWith(repoCheckoutPrefix)) {
      candidatePath = p.join(entity.path, packageGitPath, 'bin', 'glint_network.dart');
    } else if (name.startsWith('$legacyName-')) {
      candidatePath = p.join(entity.path, 'bin', '$legacyName.dart');
    } else {
      continue;
    }
    final candidate = io.File(candidatePath);
    if (!candidate.existsSync()) continue;
    final stamp = candidate.lastModifiedSync();
    if (stamp.isAfter(newestStamp)) {
      newestStamp = stamp;
      newest = candidate;
    }
  }
  return newest?.path;
}

/// A shell script that runs the native binary; [launchedAs] tells the server which command started it.
String execShim(String exePath, {String? launchedAs}) => '#!/bin/sh\n'
    '${launchedAs == null ? '' : '$launchedAsEnv=$launchedAs '}exec "$exePath" "\$@"\n';

/// The install targets: the `glint_network` wrapper, plus the `flutter_network_mcp` one when an older setup still launches through it.
List<String> _resolveOutputPaths() {
  final cache = _pubCacheDir();
  if (cache == null) return const [];
  final ext = io.Platform.isWindows ? '.bat' : '';
  final legacy = p.join(cache, 'bin', '$legacyName$ext');
  return [
    p.join(cache, 'bin', 'glint_network$ext'),
    if (io.File(legacy).existsSync()) legacy,
  ];
}

/// Resolves `$PUB_CACHE`, falling back to `$HOME/.pub-cache` on POSIX or
/// `$APPDATA/Pub/Cache` on Windows. Matches the dart-sdk default.
String? _pubCacheDir() {
  final env = networkEnv;
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
