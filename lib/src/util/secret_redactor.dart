import 'network_env.dart';

/// Masks bearer tokens, JWTs, long hex keys and `password=`-style values in free text.
String redactSecrets(String input) {
  if (input.isEmpty) return input;
  return input
      .replaceAll(_jwtRegex, '<jwt>')
      .replaceAllMapped(_bearerRegex, (m) => '${m[1]} <redacted>')
      .replaceAllMapped(_assignmentRegex, (m) => '${m[1]}${m[2]}<redacted>')
      .replaceAll(_longHexRegex, '<hex>');
}

/// The value stored or shown for a redacted header.
const redactedValue = '<redacted>';

/// A copy of [headers] with the values of every header named in [names] (lowercase) replaced by [redactedValue].
Map<String, dynamic> redactHeaderValues(
  Map<String, dynamic> headers,
  Set<String> names,
) =>
    {
      for (final e in headers.entries)
        e.key: names.contains(e.key.toLowerCase())
            ? (e.value is List ? [redactedValue] : redactedValue)
            : e.value,
    };

/// True when the user asked to keep secret header values in the capture database (`GLINT_NETWORK_STORE_SECRETS`).
bool storeSecrets([Map<String, String>? env]) {
  final v =
      (env ?? networkEnv)['GLINT_NETWORK_STORE_SECRETS']
          ?.trim()
          .toLowerCase();
  return v == 'true' || v == '1' || v == 'yes' || v == 'on';
}

final RegExp _jwtRegex =
    RegExp(r'eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}');
final RegExp _bearerRegex =
    RegExp(r'\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{8,}');
final RegExp _assignmentRegex = RegExp(
  r'''\b((?:password|passwd|pwd|secret|token|access_token|refresh_token|api[_-]?key|access[_-]?key|client[_-]?secret)"?)(\s*[:=]\s*"?)(?!<redacted>)[^\s"',;&}]+''',
  caseSensitive: false,
);
final RegExp _longHexRegex = RegExp(r'\b[A-Fa-f0-9]{40,}\b');
