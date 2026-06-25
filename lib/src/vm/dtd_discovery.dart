import 'dart:convert';
import 'dart:io' as io;

import 'package:path/path.dart' as p;

/// One DTD instance discovered on the local filesystem. Built from a
/// `package:dtd`-written discovery file in the standard per-platform
/// directory ([DtdDiscovery.discoveryDir]).
///
/// The discovery file is JSON with shape (real example):
/// ```json
/// {
///   "wsUri": "ws://127.0.0.1:54450/-y7LwW-MjnA=",
///   "epoch": 1780462678169,
///   "pid": 77534,
///   "dartVersion": "3.12.0 (stable) ...",
///   "workspaceRoot": "/Users/lukasio/StudioProjects/sanga_mobile",
///   "ideName": "Android Studio"
/// }
/// ```
///
/// The `wsUri` contains the security token in the URL path, so a caller
/// can connect immediately — no `lsof`/port-probing/token-hunting needed.
class DtdCandidate {
  DtdCandidate({
    required this.wsUri,
    required this.pid,
    required this.epoch,
    required this.discoveryFilePath,
    this.dartVersion,
    this.workspaceRoot,
    this.ideName,
    String? cwdForMatch,
  })  : _cwd = cwdForMatch,
        isLive = DtdDiscovery.isPidAlive(pid);

  final String wsUri;
  final int pid;
  final DateTime epoch;
  final String? dartVersion;
  final String? workspaceRoot;
  final String? ideName;
  final String discoveryFilePath;

  /// True when the recorded pid still responds to the OS "do you exist?"
  /// probe. Computed at construction so [DtdDiscovery.discover] can rank.
  final bool isLive;

  final String? _cwd;

  /// True when this candidate's [workspaceRoot] equals the [cwd] this
  /// discovery run was scoped to. False when either side is null or the
  /// paths differ (case-sensitive — DTD writes canonical absolute paths).
  bool get matchesCwd {
    if (_cwd == null || workspaceRoot == null) return false;
    return p.equals(_cwd, workspaceRoot!);
  }

  /// JSON snapshot used by the `network_discover_dtd` tool.
  Map<String, Object?> toJson() => {
        'wsUri': wsUri,
        'pid': pid,
        'epochMs': epoch.millisecondsSinceEpoch,
        if (dartVersion != null) 'dartVersion': dartVersion,
        if (workspaceRoot != null) 'workspaceRoot': workspaceRoot,
        if (ideName != null) 'ideName': ideName,
        'isLive': isLive,
        'matchesCwd': matchesCwd,
        'discoveryFilePath': discoveryFilePath,
      };
}

/// Lists DTD instances by reading the per-platform discovery directory.
///
/// `package:dtd` writes a discovery file every time a DTD spawns; the file
/// name is the pid. The directory differs by OS:
///
/// - macOS: `$HOME/Library/Application Support/dart/dtd`
/// - Linux: `$XDG_CONFIG_HOME/dart/dtd` (fallback `$HOME/.config/dart/dtd`)
/// - Windows: `%APPDATA%/dart/dtd`
class DtdDiscovery {
  /// Defensive cap so a pathologically-busy discovery dir can't blow the
  /// scan budget.
  static const int _maxFilesToScan = 64;

  /// Returns the absolute path of the platform-specific DTD discovery
  /// directory, or null when the env var that anchors it is missing.
  /// Does NOT check that the directory exists — caller handles that.
  static String? discoveryDir() {
    final env = io.Platform.environment;
    if (io.Platform.isMacOS) {
      final home = env['HOME'];
      if (home == null || home.isEmpty) return null;
      return p.join(home, 'Library', 'Application Support', 'dart', 'dtd');
    }
    if (io.Platform.isLinux) {
      final xdg = env['XDG_CONFIG_HOME'];
      if (xdg != null && xdg.isNotEmpty) {
        return p.join(xdg, 'dart', 'dtd');
      }
      final home = env['HOME'];
      if (home == null || home.isEmpty) return null;
      return p.join(home, '.config', 'dart', 'dtd');
    }
    if (io.Platform.isWindows) {
      final appData = env['APPDATA'];
      if (appData == null || appData.isEmpty) return null;
      return p.join(appData, 'dart', 'dtd');
    }
    return null;
  }

  /// Returns every parseable discovery file as a [DtdCandidate], sorted
  /// best-first:
  ///
  /// 1. Live process (pid responds) over dead.
  /// 2. `workspaceRoot == cwd` over mismatch over null workspaceRoot.
  /// 3. Newest `epoch` over older.
  ///
  /// Never throws — errors during scan log to stderr and produce an empty
  /// list. Auto-discovery is a convenience; a missing directory or unreadable
  /// file shouldn't crash the server.
  static List<DtdCandidate> discover({String? cwd}) {
    cwd ??= io.Directory.current.path;
    final dir = discoveryDir();
    if (dir == null) return const [];
    final dirHandle = io.Directory(dir);
    if (!dirHandle.existsSync()) return const [];

    final candidates = <DtdCandidate>[];
    try {
      var scanned = 0;
      for (final entity in dirHandle.listSync(followLinks: false)) {
        if (scanned >= _maxFilesToScan) break;
        if (entity is! io.File) continue;
        scanned++;
        final candidate = _parseFile(entity, cwd);
        if (candidate != null) candidates.add(candidate);
      }
    } catch (e) {
      io.stderr.writeln(
        'flutter_network_mcp: DTD discovery scan failed at $dir ($e). '
        'Continuing without auto-discovery.',
      );
      return const [];
    }

    candidates.sort(_rank);
    return candidates;
  }

  /// Parses one discovery file into a [DtdCandidate], or null when the
  /// file isn't recognizable (not JSON, missing `wsUri`/`pid`, etc.).
  static DtdCandidate? _parseFile(io.File file, String cwd) {
    try {
      final raw = file.readAsStringSync();
      final json = jsonDecode(raw);
      if (json is! Map<String, Object?>) return null;
      final wsUri = json['wsUri'] as String?;
      final pid = json['pid'] as int?;
      if (wsUri == null || pid == null) return null;
      final epochMs = json['epoch'] as int? ?? 0;
      return DtdCandidate(
        wsUri: wsUri,
        pid: pid,
        epoch: DateTime.fromMillisecondsSinceEpoch(epochMs),
        dartVersion: json['dartVersion'] as String?,
        workspaceRoot: json['workspaceRoot'] as String?,
        ideName: json['ideName'] as String?,
        discoveryFilePath: file.path,
        cwdForMatch: cwd,
      );
    } catch (_) {
      return null;
    }
  }

  /// Ranking comparator used by [discover]. Returns < 0 when [a] is
  /// "better" than [b]. See [discover]'s doc comment for the ranking
  /// rules.
  static int _rank(DtdCandidate a, DtdCandidate b) {
    if (a.isLive != b.isLive) return a.isLive ? -1 : 1;
    if (a.matchesCwd != b.matchesCwd) return a.matchesCwd ? -1 : 1;
    final aNullRoot = a.workspaceRoot == null;
    final bNullRoot = b.workspaceRoot == null;
    if (aNullRoot != bNullRoot) return aNullRoot ? 1 : -1;
    return b.epoch.compareTo(a.epoch);
  }

  /// Probes [pid] to see whether the OS still has a process with that id.
  ///
  /// - POSIX (macOS / Linux): `kill -0 <pid>` exits 0 when the process
  ///   exists. We invoke via `Process.runSync` so it's synchronous and
  ///   cheap (~1ms).
  /// - Windows: `tasklist /FI "PID eq <pid>" /NH` prints "INFO: No tasks
  ///   are running which match the specified criteria." when nothing
  ///   matches; otherwise it prints a row.
  ///
  /// Defaults to true on unsupported platforms — better to consider a
  /// process possibly-live than to silently discard real candidates.
  static bool isPidAlive(int pid) {
    if (pid <= 0) return false;
    try {
      if (io.Platform.isMacOS || io.Platform.isLinux) {
        final result = io.Process.runSync('kill', ['-0', pid.toString()]);
        return result.exitCode == 0;
      }
      if (io.Platform.isWindows) {
        final result = io.Process.runSync(
          'tasklist',
          ['/FI', 'PID eq $pid', '/NH'],
        );
        if (result.exitCode != 0) return false;
        final out = (result.stdout as String?) ?? '';
        return out.contains(pid.toString());
      }
    } catch (_) {
      return true;
    }
    return true;
  }
}
