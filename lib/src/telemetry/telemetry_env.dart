/// Shared environment + identity helpers for the telemetry layer.
///
/// Both the crash reporter (`TelemetryReporter`) and the usage-rollup
/// reporter (`UsageReporter`) stamp their payloads with the SAME machine
/// identity and host descriptors, so the collector can attribute a crash
/// report and a usage rollup to one install. Keeping these in one place is
/// what guarantees that parity: `machineHash` in particular MUST be
/// byte-for-byte identical across both payload kinds for cross-payload
/// dedupe to work. Duplicating it would risk silent drift.
library;

import 'dart:io' as io;
import 'dart:math';

import '../version.dart';
import 'telemetry_constants.dart';

/// A random id created once per install in [dataDir], sent as `machineHash`; unlike a hash of the path, it reveals nothing about the user.
String installId(String dataDir) {
  final file = io.File('$dataDir/install-id');
  try {
    final existing = file.readAsStringSync().trim();
    if (RegExp(r'^[0-9a-f]{24}$').hasMatch(existing)) return existing;
  } on Object {
    // Not created yet.
  }
  final rnd = Random.secure();
  final id = [
    for (var i = 0; i < 12; i++)
      rnd.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();
  try {
    io.Directory(dataDir).createSync(recursive: true);
    file.writeAsStringSync(id);
  } on Object {
    // Unwritable data dir: the id lives for this run only.
  }
  return id;
}

/// Why nothing is sent, or null when the user opted in with `FLUTTER_NETWORK_MCP_TELEMETRY=on` and nothing overrides it. [usage] also honours `FLUTTER_NETWORK_MCP_NO_USAGE`.
String? sharingOffReason({Map<String, String>? env, bool usage = false}) {
  final e = env ?? io.Platform.environment;
  if (truthyEnv(e['FLUTTER_NETWORK_MCP_NO_TELEMETRY'])) {
    return 'FLUTTER_NETWORK_MCP_NO_TELEMETRY is set';
  }
  if (usage && truthyEnv(e['FLUTTER_NETWORK_MCP_NO_USAGE'])) {
    return 'FLUTTER_NETWORK_MCP_NO_USAGE is set';
  }
  if (truthyEnv(e['DO_NOT_TRACK'])) return 'DO_NOT_TRACK is set';
  if (!truthyEnv(e['FLUTTER_NETWORK_MCP_TELEMETRY'])) {
    return 'off by default; set FLUTTER_NETWORK_MCP_TELEMETRY=on to share';
  }
  return null;
}

/// `"macos 14.6"`, operating system + truncated version. Long Linux
/// version strings (kernel + distro + build info) are capped at 60 chars
/// so the payload stays bounded.
String osDescriptor() {
  final ver = io.Platform.operatingSystemVersion;
  final trimmed = ver.length > 60 ? '${ver.substring(0, 60)}…' : ver;
  return '${io.Platform.operatingSystem} $trimmed';
}

/// Dart SDK version. `Platform.version` is `3.5.0 (stable) ... (Linux
/// X64)`; we keep just the leading semver triple.
String dartVersion() {
  final raw = io.Platform.version;
  final spaceIdx = raw.indexOf(' ');
  return spaceIdx < 0 ? raw : raw.substring(0, spaceIdx);
}

/// First 12 hex chars of the build commit SHA, or null when unknown (JIT
/// run outside a git checkout). The SHA is a nice-to-have for the
/// maintainer, never load-bearing.
String? shortCommit() {
  final sha = currentCommitSha();
  if (sha == null) return null;
  return sha.length > 12 ? sha.substring(0, 12) : sha;
}

/// POSTs [jsonStr] to [kCollectorEndpoint] with the telemetry User-Agent.
/// Returns the HTTP status; throws on connection failure (callers swallow
/// it). Contract: callers MUST check `kCollectorEndpoint.isNotEmpty`
/// before calling, since an empty endpoint means local-only mode.
Future<int> postTelemetry(String jsonStr) async {
  final client = io.HttpClient()
    ..connectionTimeout = kTelemetryTimeout
    ..userAgent = kTelemetryUserAgent;
  try {
    final request = await client
        .postUrl(Uri.parse(kCollectorEndpoint))
        .timeout(kTelemetryTimeout);
    request.headers.contentType = io.ContentType.json;
    request.write(jsonStr);
    final response = await request.close().timeout(kTelemetryTimeout);
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close(force: true);
  }
}

/// True when telemetry is globally disabled via env
/// (`FLUTTER_NETWORK_MCP_NO_TELEMETRY`). The usage reporter layers the
/// granular `FLUTTER_NETWORK_MCP_NO_USAGE` opt-out on top of this.
bool telemetryDisabled([Map<String, String>? env]) {
  final e = env ?? io.Platform.environment;
  return truthyEnv(e['FLUTTER_NETWORK_MCP_NO_TELEMETRY']);
}

/// Treats `true` / `1` / `yes` / `on` (case-insensitive, trimmed) as true.
bool truthyEnv(String? v) {
  final s = v?.trim().toLowerCase();
  return s == 'true' || s == '1' || s == 'yes' || s == 'on';
}
