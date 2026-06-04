/// Strips filesystem identity from arbitrary text — typically Dart stack
/// frames — so it's safe to ship off the user's machine.
///
/// Two threats to handle:
/// 1. **POSIX `$HOME` paths**: `/Users/lukasio/StudioProjects/sanga_mobile/lib/main.dart`
///    leaks the username, project name, and parent dir layout.
/// 2. **Windows `%USERPROFILE%` paths**: `C:\Users\lukasio\code\app\lib\main.dart`
///    same problem.
///
/// The redactor replaces:
/// - `/Users/<name>/StudioProjects/<project>/...` → `<project>/...`
/// - `/Users/<name>/...` → `<home>/...`
/// - `C:\Users\<name>\<project>\...` → `<project>\...`
/// - `C:\Users\<name>\...` → `<home>\...`
///
/// `package:` URIs in stack frames are left untouched — they're already
/// package-relative and contain no filesystem identity (`package:
/// flutter_network_mcp/src/auto_attach.dart:189` is exactly what we want
/// the collector to see).
///
/// Idempotent: running the redactor twice produces the same output.
String redactPath(String input) {
  if (input.isEmpty) return input;
  var s = input;
  // Project-aware redaction FIRST — most specific match wins.
  s = s.replaceAllMapped(_posixStudioProjectsRegex, (m) {
    return '<project:${m.group(1)}>/';
  });
  s = s.replaceAllMapped(_windowsStudioProjectsRegex, (m) {
    return r'<project:' '${m.group(1)}' r'>\';
  });
  // Generic homedir fallback.
  s = s.replaceAll(_posixHomeRegex, '<home>/');
  s = s.replaceAll(_windowsHomeRegex, r'<home>\');
  return s;
}

/// Redacts every line of a Dart stack trace. Splits on `\n`, redacts each
/// line independently, keeps the first [maxFrames] frames. Used by the
/// telemetry payload builder to ship a bounded `stackHead`.
List<String> redactStackHead(StackTrace stack, {int maxFrames = 8}) {
  final lines = stack.toString().split('\n');
  final head = <String>[];
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    head.add(redactPath(trimmed));
    if (head.length >= maxFrames) break;
  }
  return head;
}

/// `/Users/<name>/StudioProjects/<project>/` — captures the project name
/// so we can preserve it as a non-identifying label.
final RegExp _posixStudioProjectsRegex =
    RegExp(r'/Users/[^/]+/StudioProjects/([^/]+)/');

/// Generic POSIX homedir fallback.
final RegExp _posixHomeRegex = RegExp(r'/Users/[^/]+/');

/// `C:\Users\<name>\StudioProjects\<project>\` — Windows analog of the
/// POSIX rule. Captures the project name under StudioProjects so we keep
/// the non-identifying label.
final RegExp _windowsStudioProjectsRegex =
    RegExp(r'C:\\Users\\[^\\]+\\StudioProjects\\([^\\]+)\\');

/// Generic Windows homedir fallback.
final RegExp _windowsHomeRegex = RegExp(r'C:\\Users\\[^\\]+\\');
