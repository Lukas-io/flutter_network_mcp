import 'dart:convert';
import 'dart:io' as io;

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Tamper-evident append-only telemetry audit log.
///
/// One line per entry, format:
///
///   <ts>|<prev_hash>|<payload_b64>|<this_hash>
///
/// - `ts` — ISO-8601 UTC timestamp (writer's local clock at append time).
/// - `prev_hash` — SHA-256 hex of the previous line's `this_hash`. First
///   entry uses [_zeroHash] (64 zeros).
/// - `payload_b64` — base64 of the EXACT JSON bytes that were sent (or
///   would have been, if the network attempt failed). Byte-for-byte
///   parity with the POST body.
/// - `this_hash` — SHA-256 hex of `<ts>|<prev_hash>|<payload_b64>`.
///
/// Tamper-EVIDENT, not tamper-PROOF. The user owns the file; they CAN
/// edit it. The hash chain makes any edit detectable: change one line
/// and its `this_hash` no longer matches the input; remove a line and
/// the next line's `prev_hash` no longer matches the chain. The same
/// trust model as `git log`.
///
/// File location: `<dataDir>/telemetry-audit.log`. Caller passes the
/// data dir explicitly so this code has no dependency on the
/// `CapturesDatabase` singleton (callable from anywhere).
class AuditLog {
  static const String fileName = 'telemetry-audit.log';
  static const String _zeroHash =
      '0000000000000000000000000000000000000000000000000000000000000000';

  /// Appends one entry. [payloadJson] must be the exact JSON bytes (as a
  /// String) that hit (or would have hit) the wire. Returns the
  /// resulting [AuditEntry]. Throws on filesystem failure — callers in
  /// the telemetry path wrap this in try/catch since the audit log is
  /// best-effort.
  static AuditEntry append(String dataDir, String payloadJson) {
    final path = _filePath(dataDir);
    final file = io.File(path);
    if (!file.parent.existsSync()) {
      file.parent.createSync(recursive: true);
    }
    final prevHash = _lastHash(file) ?? _zeroHash;
    final ts = DateTime.now().toUtc().toIso8601String();
    final payloadB64 = base64.encode(utf8.encode(payloadJson));
    final preimage = '$ts|$prevHash|$payloadB64';
    final thisHash = sha256.convert(utf8.encode(preimage)).toString();
    final line = '$preimage|$thisHash\n';
    file.writeAsStringSync(line, mode: io.FileMode.append, flush: true);
    return AuditEntry(
      ts: DateTime.parse(ts),
      prevHash: prevHash,
      payloadB64: payloadB64,
      thisHash: thisHash,
    );
  }

  /// Reads + parses every entry. Returns empty list when the file is
  /// missing. Malformed lines surface as `null` placeholders so the
  /// verifier can flag them at their actual index.
  static List<AuditEntry?> readAll(String dataDir) {
    final file = io.File(_filePath(dataDir));
    if (!file.existsSync()) return const [];
    final out = <AuditEntry?>[];
    for (final raw in file.readAsLinesSync()) {
      if (raw.isEmpty) continue;
      out.add(AuditEntry.tryParse(raw));
    }
    return out;
  }

  /// Walks the chain. Verifies (1) each line's `this_hash` matches a
  /// fresh SHA-256 of its preimage, (2) each line's `prev_hash` matches
  /// the previous line's `this_hash`. Stops at the first break and
  /// records its index + reason. Returns intact result when no entries
  /// exist (vacuously true).
  static AuditVerifyResult verify(String dataDir) {
    final entries = readAll(dataDir);
    if (entries.isEmpty) {
      return const AuditVerifyResult(
        totalEntries: 0,
        intact: true,
        firstTs: null,
        lastTs: null,
      );
    }
    String previousThisHash = _zeroHash;
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      if (entry == null) {
        return AuditVerifyResult(
          totalEntries: entries.length,
          intact: false,
          brokenAtIndex: i,
          brokenReason: 'malformed line',
          firstTs: entries.first?.ts,
          lastTs: null,
        );
      }
      if (entry.prevHash != previousThisHash) {
        return AuditVerifyResult(
          totalEntries: entries.length,
          intact: false,
          brokenAtIndex: i,
          brokenReason: 'prev_hash mismatch (expected '
              '${_short(previousThisHash)}, got ${_short(entry.prevHash)})',
          firstTs: entries.first?.ts,
          lastTs: null,
        );
      }
      final preimage = '${entry.ts.toIso8601String()}|${entry.prevHash}|${entry.payloadB64}';
      final recomputed = sha256.convert(utf8.encode(preimage)).toString();
      if (recomputed != entry.thisHash) {
        return AuditVerifyResult(
          totalEntries: entries.length,
          intact: false,
          brokenAtIndex: i,
          brokenReason: 'this_hash mismatch (recomputed '
              '${_short(recomputed)}, recorded ${_short(entry.thisHash)})',
          firstTs: entries.first?.ts,
          lastTs: null,
        );
      }
      previousThisHash = entry.thisHash;
    }
    return AuditVerifyResult(
      totalEntries: entries.length,
      intact: true,
      firstTs: entries.first?.ts,
      lastTs: entries.last?.ts,
    );
  }

  static String _filePath(String dataDir) => p.join(dataDir, fileName);

  static String? _lastHash(io.File file) {
    if (!file.existsSync()) return null;
    final lines = file.readAsLinesSync();
    for (var i = lines.length - 1; i >= 0; i--) {
      final line = lines[i];
      if (line.isEmpty) continue;
      final parts = line.split('|');
      if (parts.length == 4) return parts[3];
    }
    return null;
  }

  static String _short(String hash) =>
      hash.length <= 12 ? hash : '${hash.substring(0, 12)}…';
}

/// One parsed entry from the audit log.
class AuditEntry {
  const AuditEntry({
    required this.ts,
    required this.prevHash,
    required this.payloadB64,
    required this.thisHash,
  });

  final DateTime ts;
  final String prevHash;
  final String payloadB64;
  final String thisHash;

  /// Decodes the payload back to JSON bytes (UTF-8 → String). Used by
  /// `audit show` to pretty-print what got sent.
  String decodePayload() => utf8.decode(base64.decode(payloadB64));

  /// Returns null when the line doesn't have the expected 4-part shape.
  static AuditEntry? tryParse(String line) {
    final parts = line.split('|');
    if (parts.length != 4) return null;
    final ts = DateTime.tryParse(parts[0]);
    if (ts == null) return null;
    if (parts[1].length != 64 || parts[3].length != 64) return null;
    return AuditEntry(
      ts: ts,
      prevHash: parts[1],
      payloadB64: parts[2],
      thisHash: parts[3],
    );
  }
}

class AuditVerifyResult {
  const AuditVerifyResult({
    required this.totalEntries,
    required this.intact,
    this.brokenAtIndex,
    this.brokenReason,
    this.firstTs,
    this.lastTs,
  });

  final int totalEntries;
  final bool intact;

  /// Zero-based index of the broken line. Null when [intact] is true.
  final int? brokenAtIndex;

  /// Human-readable reason for the break.
  final String? brokenReason;

  final DateTime? firstTs;
  final DateTime? lastTs;
}
