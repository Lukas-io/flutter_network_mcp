import 'dart:io';

import '../util/secret_redactor.dart';

/// Strips filesystem identity (username, project name, directory layout) from text that leaves the machine: telemetry, issue bodies.
/// `<home>/…/lib/x.dart` collapses to `<project>/lib/x.dart`; `package:` URIs are untouched; idempotent.
String redactPath(String input, {String? home}) {
  if (input.isEmpty) return input;
  var s = input;
  final h = home ?? _homeDir();
  if (h != null && h.length > 1) {
    s = s.replaceAll(
        '$h${Platform.pathSeparator}', '<home>${Platform.pathSeparator}');
    s = s.replaceAll('$h/', '<home>/');
  }
  s = s.replaceAll(_posixHomeRegex, '<home>/');
  s = s.replaceAll(_windowsHomeRegex, r'<home>\');
  s = s.replaceAllMapped(_posixProjectRegex, (m) => '<project>/${m[1]}/');
  s = s.replaceAllMapped(_windowsProjectRegex, (m) => '<project>\\${m[1]}\\');
  return s;
}

/// Redacts every line of a Dart stack trace, keeping the first [maxFrames] frames.
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

/// [redactPath] and [redactSecrets] together, for anything posted publicly.
String redactForSharing(String input) => redactSecrets(redactPath(input));

String? _homeDir() {
  final env = Platform.environment;
  final h = Platform.isWindows ? env['USERPROFILE'] : env['HOME'];
  if (h == null || h.isEmpty) return null;
  return h.endsWith('/') || h.endsWith(r'\') ? h.substring(0, h.length - 1) : h;
}

final RegExp _posixHomeRegex =
    RegExp(r'(?:/Users/[^/\s]+|/home/[^/\s]+|/root)/');
final RegExp _windowsHomeRegex = RegExp(r'[A-Za-z]:\\Users\\[^\\\s]+\\');
final RegExp _posixProjectRegex =
    RegExp(r'<home>/(?:[^/\s()]+/)*?(lib|test|bin|integration_test|tool)/');
final RegExp _windowsProjectRegex =
    RegExp(r'<home>\\(?:[^\\\s()]+\\)*?(lib|test|bin|integration_test|tool)\\');
