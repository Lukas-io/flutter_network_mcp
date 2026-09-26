import 'dart:io' as io;

/// Prefix of glint_network's environment variables.
const String envPrefix = 'GLINT_NETWORK_';

/// Prefix the same variables had as flutter_network_mcp; still read, with a deprecation warning.
const String legacyEnvPrefix = 'FLUTTER_NETWORK_MCP_';

/// [source] plus each legacy `FLUTTER_NETWORK_MCP_*` variable under its `GLINT_NETWORK_*` name, unless that name is already set.
Map<String, String> withLegacyNames(Map<String, String> source) {
  final legacy = legacyEnvNames(source);
  if (legacy.isEmpty) return source;
  return {
    ...source,
    for (final name in legacy)
      if (!source.containsKey(currentEnvName(name))) currentEnvName(name): source[name]!,
  };
}

/// The `GLINT_NETWORK_*` name for a legacy [name].
String currentEnvName(String name) => '$envPrefix${name.substring(legacyEnvPrefix.length)}';

/// Legacy `FLUTTER_NETWORK_MCP_*` names set in [source], sorted.
List<String> legacyEnvNames(Map<String, String> source) =>
    source.keys.where((k) => k.startsWith(legacyEnvPrefix)).toList()..sort();

/// The process environment with legacy names mapped; read this instead of `Platform.environment`.
final Map<String, String> networkEnv = withLegacyNames(io.Platform.environment);
