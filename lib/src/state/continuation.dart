import 'dart:convert';
import 'dart:io' as io;

import 'package:path/path.dart' as p;

import '../util/data_dir.dart';
import 'session.dart';

/// Persists the set of currently-attached sessions across MCP-host
/// restarts. Lets the agent's first `network_status` after a Claude
/// Code reload say "you were on sanga_mobile 47 min ago, here's the
/// reattach command" — zero user friction.
///
/// File location: `<data-dir>/last-session.json`. Written on every
/// successful attach + detach; cleared when nothing is attached
/// anymore. All I/O is best-effort — write/read failures stay silent
/// so a transient FS hiccup never breaks the attach/detach path.
class SessionContinuation {
  static const String fileName = 'last-session.json';

  /// Writes the current attachment set. Pass the registry's full
  /// `attached.values.toList()` so multi-attach is preserved.
  static void record(Iterable<AttachedSession> attached) {
    try {
      final dataDir = resolveCandidateDataDir();
      if (dataDir == null) return;
      final dir = io.Directory(dataDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final list = attached.toList();
      if (list.isEmpty) {
        _clearAt(dataDir);
        return;
      }
      final payload = <String, Object?>{
        'writtenAtMs': DateTime.now().millisecondsSinceEpoch,
        'attachments': [
          for (final s in list)
            <String, Object?>{
              'vmServiceUri': s.vmServiceUri,
              if (s.appName != null) 'appName': s.appName,
              'attachedAtMs': s.attachedAt.millisecondsSinceEpoch,
            },
        ],
      };
      io.File(p.join(dataDir, fileName)).writeAsStringSync(
        jsonEncode(payload),
      );
    } catch (_) {/* best-effort */}
  }

  /// Deletes the continuation file. Called when the registry hits
  /// zero attached sessions.
  static void clear() {
    try {
      final dataDir = resolveCandidateDataDir();
      if (dataDir == null) return;
      _clearAt(dataDir);
    } catch (_) {/* best-effort */}
  }

  static void _clearAt(String dataDir) {
    final file = io.File(p.join(dataDir, fileName));
    if (file.existsSync()) file.deleteSync();
  }

  /// Best-effort read. Returns null when the file is missing or
  /// malformed — the agent treats that as "no continuation available."
  static Map<String, Object?>? read() {
    try {
      final dataDir = resolveCandidateDataDir();
      if (dataDir == null) return null;
      final file = io.File(p.join(dataDir, fileName));
      if (!file.existsSync()) return null;
      final raw = file.readAsStringSync();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return decoded.cast<String, Object?>();
    } catch (_) {
      return null;
    }
  }
}
