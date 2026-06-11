import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:crypto/crypto.dart';

import '../util/data_dir.dart';
import '../version.dart';
import 'audit_log.dart';
import 'path_redactor.dart';
import 'telemetry_constants.dart';

/// Crash telemetry reporter.
///
/// Wired from `bin/flutter_network_mcp.dart`'s top-level
/// `runZonedGuarded` handler — every uncaught error becomes a
/// fire-and-forget call to [maybeReport].
///
/// Two writes per call (in this order):
/// 1. **Local audit log** (always, if telemetry is enabled): appended to
///    `<data-dir>/telemetry-audit.log` BEFORE the network attempt so the
///    user can see what would have been sent even when the wire send
///    fails.
/// 2. **HTTPS POST** (only when [kCollectorEndpoint] is non-empty):
///    fire-and-forget with a 3s deadline. All errors swallowed.
///
/// Opt-out: `FLUTTER_NETWORK_MCP_NO_TELEMETRY=true` short-circuits
/// the whole path — no audit write, no network attempt.
///
/// **Privacy-first by design**: see [buildTelemetryPayload] for the full
/// schema. No PII, no source paths, no captured app data.
class TelemetryReporter {
  /// Fire-and-forget entry point. Caller MUST NOT await this in a path
  /// that blocks shutdown — use `unawaited(...)`.
  static Future<void> maybeReport({
    required Object error,
    required StackTrace stack,
  }) async {
    try {
      final env = io.Platform.environment;
      if (env['FLUTTER_NETWORK_MCP_NO_TELEMETRY']?.toLowerCase() == 'true') {
        return;
      }
      final dataDir = resolveCandidateDataDir();
      if (dataDir == null) return;

      final payload = buildTelemetryPayload(
        error: error,
        stack: stack,
        dataDir: dataDir,
      );
      final jsonStr = jsonEncode(payload);

      // Always write the audit log first. Failure is non-fatal (the
      // network attempt still runs).
      try {
        AuditLog.append(dataDir, jsonStr);
      } catch (_) {/* audit log is best-effort */}

      // Network POST only when a real endpoint is baked in. Path B
      // (default 0.7.1) ships with empty constant → audit-log-only.
      if (kCollectorEndpoint.isNotEmpty) {
        await _post(jsonStr).timeout(kTelemetryTimeout).catchError((_) => -1);
      }
    } catch (_) {
      // Belt-and-suspenders: nothing inside this method should propagate.
      // The runZonedGuarded handler is the last line of defense before
      // process exit; an exception here would replace the original
      // error in stderr — unacceptable.
    }
  }

  /// Visible for testing. POSTs the [jsonStr] payload to the configured
  /// collector with a User-Agent header. Returns the HTTP status; throws
  /// on connection failure (caller's `.catchError` swallows it).
  static Future<int> _post(String jsonStr) async {
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
      // Drain response to free the socket.
      await response.drain<void>();
      return response.statusCode;
    } finally {
      client.close(force: true);
    }
  }
}

/// Builds the wire payload. Visible for testing — `TelemetryReporter`
/// wraps this with the env-var gate + audit-log write + POST.
///
/// **Schema** (what's IN):
/// ```jsonc
/// {
///   "version": "0.7.1",
///   "commit": "4aa550c...",         // 12-char hex; null when SHA unknown
///   "isAot": true,
///   "os": "macos 14.6",             // platform.os + truncated version
///   "dart": "3.5.0",                // platform.version, version-only
///   "errorClass": "StateError",     // error.runtimeType.toString()
///   "errorMessage": "DTD is not connected.",  // truncated 200 chars
///   "stackHead": ["#0 frame...", "#1 frame...", ...],  // 8 frames, paths redacted
///   "signature": "a3f7c8d219b4",    // dedupe key, sha256(errorClass + top-3)[:12]
///   "machineHash": "f1a823bc91...", // HMAC(dataDir, salt)[:24]
///   "reportedAt": "2026-06-04T12:34:56Z"
/// }
/// ```
///
/// **What's NOT in**: `$HOME`, `cwd`, target project path, vmServiceUri,
/// DTD URI, captured HTTP bodies / headers / URLs, env-var contents,
/// any `captures.db` row contents.
Map<String, Object?> buildTelemetryPayload({
  required Object error,
  required StackTrace stack,
  required String dataDir,
}) {
  final errorClass = error.runtimeType.toString();
  final errorMessage = _truncate(error.toString(), kErrorMessageMaxChars);
  final stackHead = redactStackHead(stack, maxFrames: kStackHeadFrames);
  final signature = _signature(errorClass, stackHead);
  final machineHash = _machineHash(dataDir);
  final commit = currentCommitSha();
  final commitShort = commit == null
      ? null
      : (commit.length > 12 ? commit.substring(0, 12) : commit);

  return <String, Object?>{
    'version': packageVersion,
    if (commitShort != null) 'commit': commitShort,
    'isAot': isAotBuild,
    'os': _os(),
    'dart': _dart(),
    'errorClass': errorClass,
    if (errorMessage.isNotEmpty) 'errorMessage': errorMessage,
    'stackHead': stackHead,
    'signature': signature,
    'machineHash': machineHash,
    'reportedAt': DateTime.now().toUtc().toIso8601String(),
  };
}

String _truncate(String s, int max) {
  if (s.length <= max) return s;
  return '${s.substring(0, max)}…(${s.length} chars)';
}

/// `sha256(errorClass + ':' + top-3-frames)[:12]`. Identical bugs across
/// machines + versions collapse to one signature, so the collector can
/// `GROUP BY signature` to find the most common crashes.
String _signature(String errorClass, List<String> stackHead) {
  final top = stackHead.take(3).join('\n');
  final digest = sha256.convert(utf8.encode('$errorClass:$top'));
  return digest.toString().substring(0, 12);
}

/// `HMAC-SHA256(dataDirPath, kPublicSalt)[:24]`. Lets the collector
/// dedupe per-machine activity without ever learning a value it could
/// reverse to the user's identity — the salt is public but the dataDir
/// is user-specific, and HMAC's one-way property prevents inversion.
String _machineHash(String dataDir) {
  final hmac = Hmac(sha256, utf8.encode(kPublicSalt));
  final digest = hmac.convert(utf8.encode(dataDir));
  return digest.toString().substring(0, 24);
}

/// `"macos 14.6"` — operating system + truncated version. Long Linux
/// version strings (often kernel + distro + build info) get capped at
/// 60 chars so the payload stays bounded.
String _os() {
  final ver = io.Platform.operatingSystemVersion;
  final trimmed = ver.length > 60 ? '${ver.substring(0, 60)}…' : ver;
  return '${io.Platform.operatingSystem} $trimmed';
}

/// Dart SDK version. `Platform.version` carries `3.5.0 (stable) ...
/// (Linux X64)` shape; we keep just the leading semver triple.
String _dart() {
  final raw = io.Platform.version;
  final spaceIdx = raw.indexOf(' ');
  if (spaceIdx < 0) return raw;
  return raw.substring(0, spaceIdx);
}
