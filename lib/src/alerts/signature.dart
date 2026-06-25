import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Stable identifier for grouping alerts that reflect "the same underlying
/// issue" even when source events differ.
///
/// Computed as `sha256(kind + ':' + normalizedTitle)[:12]`. Normalization
/// strips per-event variation (digits, hex ids, user-home paths) while
/// preserving the structural words that distinguish one bug from another.
///
/// Example:
///   `"Flutter error: RenderFlex overflowed by 14 pixels on the right"` →
///   normalized `"flutter error: renderflex overflowed by N pixels on the right"` →
///   signature `a3f7c8d219b4`. A second occurrence with `22 pixels` produces
///   the SAME signature, so the alerts pipeline collapses both into one row
///   with `occurrence_count` incremented.
///
/// Stable across processes: only depends on the input strings + the
/// normalization rules below. No randomness, no clock dependency.
String computeAlertSignature({
  required String kind,
  required String title,
}) {
  final normalized = normalizeAlertTitle(title);
  final digest = sha256.convert(utf8.encode('$kind:$normalized'));
  return digest.toString().substring(0, 12);
}

/// Visible for testing. Applies the title-normalization pipeline that
/// `computeAlertSignature` uses internally:
///
/// 1. Lowercase.
/// 2. Replace POSIX `/Users/<name>/…` with `<home>/…`.
/// 3. Replace Windows `C:\Users\<name>\…` with `<home>\…`.
/// 4. Collapse project-path segments under `StudioProjects/<x>/` to
///    `<project>/…` so the same widget in two projects can still match.
/// 5. Replace runs of `[0-9]+` with `N` (collapses ids, line numbers,
///    pixel counts, durations, status codes — they vary per event).
/// 6. Replace hex strings `[a-f0-9]{8,}` with `H` (request ids, log row
///    ids).
/// 7. Collapse runs of whitespace to a single space, trim.
///
/// Order matters: paths first, then digits, then hex (so hex catches what
/// digits don't, and paths don't accidentally consume digits).
String normalizeAlertTitle(String input) {
  var s = input.toLowerCase();

  s = s.replaceAll(_posixHomeRegex, '<home>/');
  s = s.replaceAll(_windowsHomeRegex, r'<home>\');
  s = s.replaceAll(_studioProjectsRegex, '<project>/');

  s = s.replaceAll(_digitsRegex, 'N');
  s = s.replaceAll(_hexRegex, 'H');

  s = s.replaceAll(_wsRegex, ' ').trim();

  return s;
}

final RegExp _posixHomeRegex = RegExp(r'/users/[^/]+/');
final RegExp _windowsHomeRegex = RegExp(r'c:\\users\\[^\\]+\\');
final RegExp _studioProjectsRegex =
    RegExp(r'studioprojects/[^/]+/');
final RegExp _digitsRegex = RegExp(r'[0-9]+');
final RegExp _hexRegex = RegExp(r'[a-f0-9]{8,}');
final RegExp _wsRegex = RegExp(r'\s+');
