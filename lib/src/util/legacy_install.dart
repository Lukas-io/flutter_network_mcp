import 'dart:io' as io;

import '../install/repo_layout.dart';
import 'network_env.dart';

/// When the flutter_network_mcp names, env vars and update path stop working.
const String legacySunset = '26 December 2026';

/// Set by the exec shim `install` writes for the `flutter_network_mcp` command, which hides the wrapper from the process tree.
const String launchedAsEnv = 'GLINT_NETWORK_LAUNCHED_AS';

/// How this install still leans on the flutter_network_mcp names, and what moves it over.
class LegacyUse {
  const LegacyUse({this.oldPackage = false, this.oldCommand = false, this.oldEnvNames = const []});

  /// Installed from the old flutter_network_mcp repository.
  final bool oldPackage;

  /// Started by the `flutter_network_mcp` command.
  final bool oldCommand;

  final List<String> oldEnvNames;

  bool get any => oldPackage || oldCommand || oldEnvNames.isNotEmpty;

  List<String> get steps => [
        if (oldPackage) 'run `$legacyName update`; it moves this install to the glint repository',
        if (oldCommand)
          'in your MCP config, rename the server entry to "glint-network", set its command to '
              '`glint_network`, and restart your agent host',
        for (final name in oldEnvNames) 'rename $name to ${currentEnvName(name)}',
      ];

  /// The notice to show the user; null when nothing old is in use.
  String? get notice => any
      ? 'flutter_network_mcp is now glint_network (https://github.com/Lukas-io/glint), and the old '
          'names stop working on $legacySunset. To move over: ${steps.join('; ')}.'
      : null;
}

/// Reads the signals once: package name, the launching command (env marker, then parent process), and env var names.
LegacyUse detectLegacyUse({
  String package = packageName,
  Map<String, String>? env,
  String? parentCommand,
}) {
  final e = env ?? networkEnv;
  return LegacyUse(
    oldPackage: package == legacyName,
    oldCommand: e[launchedAsEnv] == legacyName ||
        (parentCommand != null
            ? launchedByLegacyCommand(parentCommand)
            : env == null && _ancestorCommands().any(launchedByLegacyCommand)),
    oldEnvNames: legacyEnvNames(e),
  );
}

/// True when [command] runs pub's `flutter_network_mcp` wrapper, e.g. `sh ~/.pub-cache/bin/flutter_network_mcp`.
bool launchedByLegacyCommand(String? command) =>
    command != null && RegExp('(^|[/\\s])$legacyName(\\s|\$)').hasMatch(command);

/// The legacy use of this process, computed on first read.
final LegacyUse legacyUse = detectLegacyUse();

/// Commands of this process's ancestors, nearest first; `dart pub global run` puts the server two levels below pub's wrapper script.
List<String> _ancestorCommands() {
  final commands = <String>[];
  try {
    var pid = '${io.pid}';
    for (var depth = 0; depth < 4; depth++) {
      final row = io.Process.runSync('ps', ['-o', 'ppid=,command=', '-p', pid]).stdout.toString().trim();
      final m = RegExp(r'^(\d+)\s+(.*)$').firstMatch(row);
      if (m == null) break;
      pid = m.group(1)!;
      if (pid == '0' || pid == '1') break;
      final parent = io.Process.runSync('ps', ['-o', 'command=', '-p', pid]).stdout.toString().trim();
      if (parent.isEmpty) break;
      commands.add(parent);
    }
  } catch (_) {}
  return commands;
}
