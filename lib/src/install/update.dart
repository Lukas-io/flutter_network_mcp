import 'dart:io' as io;

import 'install.dart';

/// `flutter_network_mcp update` subcommand: re-runs
/// `dart pub global activate -s git ...` to fetch the latest source from
/// `master`, then re-AOTs the binary if the user previously ran
/// `flutter_network_mcp install` (detected via the `.compiled` marker
/// written by [runInstall]).
///
/// User-initiated only. The MCP server NEVER auto-runs this from the
/// running process — self-update from a live process would break the
/// MCP-host handshake and risk replacing the binary mid-call. The startup
/// version check (`UpdateCheck`) nudges the user toward this subcommand
/// when an upgrade is available; running it is up to them.
Future<void> runUpdate(List<String> args) async {
  const repo = 'https://github.com/Lukas-io/flutter_network_mcp.git';

  io.stderr.writeln(
    'flutter_network_mcp update: re-activating from $repo …',
  );

  final io.Process activate;
  try {
    activate = await io.Process.start(
      'dart',
      ['pub', 'global', 'activate', '-s', 'git', repo],
      mode: io.ProcessStartMode.inheritStdio,
    );
  } on io.ProcessException catch (e) {
    io.stderr.writeln(
      'flutter_network_mcp update: failed to spawn `dart` (${e.message}). '
      'Is the Dart SDK on your PATH? Install from https://dart.dev/get-dart, '
      'verify with `which dart`, then retry.',
    );
    io.exitCode = 127;
    return;
  }
  final activateCode = await activate.exitCode;
  if (activateCode != 0) {
    io.stderr.writeln(
      'flutter_network_mcp update: pub global activate exited '
      '$activateCode. See dart output above.',
    );
    io.exitCode = activateCode;
    return;
  }

  // If the user previously AOT-compiled, re-compile so the upgrade
  // doesn't silently downgrade them back to the slow JIT wrapper.
  if (wantsAotAfterUpdate()) {
    io.stderr.writeln(
      'flutter_network_mcp update: re-compiling (you previously ran '
      '`flutter_network_mcp install`) …',
    );
    await runInstall(const []);
    if (io.exitCode != 0) {
      io.stderr.writeln(
        'flutter_network_mcp update: re-compile failed. The JIT wrapper '
        'is in place from `pub global activate` — restart your MCP host '
        'to pick it up. Run `flutter_network_mcp install` manually to '
        're-attempt the AOT compile.',
      );
      return;
    }
  }

  io.stderr.writeln(
    'flutter_network_mcp update: done. Restart your MCP host to load '
    'the new version.',
  );
}
