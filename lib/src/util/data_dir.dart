import 'dart:io' as io;

import 'package:path/path.dart' as p;
import 'network_env.dart';

/// Resolves the user's data-dir path WITHOUT requiring `CapturesDatabase`
/// to be open. Mirrors the canonical-path candidate that
/// `CapturesDatabase._candidateDataDirs` tries first, so install /
/// telemetry / `.compiled` marker / audit log all land in the same
/// directory.
///
/// Order:
/// 1. `GLINT_NETWORK_DATA_DIR` env override.
/// 2. macOS: `$HOME/Library/Application Support/flutter_network_mcp`.
/// 3. Linux + others with `$XDG_DATA_HOME`:
///    `$XDG_DATA_HOME/flutter_network_mcp`.
/// 4. Linux + others without XDG: `$HOME/.local/share/flutter_network_mcp`.
///
/// Returns null when no usable home env var is set (rare — sandboxed CI
/// containers). Callers should treat null as "skip filesystem-side work."
/// The data directory keeps its flutter_network_mcp name so existing captures survive the rename to glint_network.
const String dataDirName = 'flutter_network_mcp';

String? resolveCandidateDataDir() {
  final env = networkEnv;
  final override = env['GLINT_NETWORK_DATA_DIR'];
  if (override != null && override.isNotEmpty) return override;
  final home = env['HOME'];
  if (home == null || home.isEmpty) return null;
  if (io.Platform.isMacOS) {
    return p.join(home, 'Library', 'Application Support', dataDirName);
  }
  final xdg = env['XDG_DATA_HOME'];
  if (xdg != null && xdg.isNotEmpty) {
    return p.join(xdg, dataDirName);
  }
  return p.join(home, '.local', 'share', dataDirName);
}
