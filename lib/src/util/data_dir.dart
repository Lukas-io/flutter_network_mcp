import 'dart:io' as io;

import 'package:path/path.dart' as p;

/// Resolves the user's data-dir path WITHOUT requiring `CapturesDatabase`
/// to be open. Mirrors the canonical-path candidate that
/// `CapturesDatabase._candidateDataDirs` tries first, so install /
/// telemetry / `.compiled` marker / audit log all land in the same
/// directory.
///
/// Order:
/// 1. `FLUTTER_NETWORK_MCP_DATA_DIR` env override.
/// 2. macOS: `$HOME/Library/Application Support/flutter_network_mcp`.
/// 3. Linux + others with `$XDG_DATA_HOME`:
///    `$XDG_DATA_HOME/flutter_network_mcp`.
/// 4. Linux + others without XDG: `$HOME/.local/share/flutter_network_mcp`.
///
/// Returns null when no usable home env var is set (rare — sandboxed CI
/// containers). Callers should treat null as "skip filesystem-side work."
String? resolveCandidateDataDir() {
  final env = io.Platform.environment;
  final override = env['FLUTTER_NETWORK_MCP_DATA_DIR'];
  if (override != null && override.isNotEmpty) return override;
  final home = env['HOME'];
  if (home == null || home.isEmpty) return null;
  if (io.Platform.isMacOS) {
    return p.join(home, 'Library', 'Application Support', 'flutter_network_mcp');
  }
  final xdg = env['XDG_DATA_HOME'];
  if (xdg != null && xdg.isNotEmpty) {
    return p.join(xdg, 'flutter_network_mcp');
  }
  return p.join(home, '.local', 'share', 'flutter_network_mcp');
}
