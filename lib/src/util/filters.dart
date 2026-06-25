bool methodMatches(String reqMethod, List<String>? methods) {
  if (methods == null || methods.isEmpty) return true;
  final m = reqMethod.toUpperCase();
  return methods.any((x) => x.toUpperCase() == m);
}

bool hostMatches(String reqUri, String? hostContains) {
  if (hostContains == null || hostContains.isEmpty) return true;
  final needle = hostContains.toLowerCase();
  try {
    final host = Uri.parse(reqUri).host.toLowerCase();
    return host.contains(needle);
  } catch (_) {
    return reqUri.toLowerCase().contains(needle);
  }
}

bool statusInRange(int? status, int? min, int? max) {
  if (min == null && max == null) return true;
  if (status == null) return false;
  if (min != null && status < min) return false;
  if (max != null && status > max) return false;
  return true;
}

/// Clamps a list parameter into a sane range. Negative/zero → fallback.
int clampLimit(int? value, {required int fallback, required int hardMax}) {
  if (value == null || value <= 0) return fallback;
  return value > hardMax ? hardMax : value;
}

List<String>? readStringList(Object? raw) {
  if (raw == null) return null;
  if (raw is List) {
    return raw.map((e) => e.toString()).toList();
  }
  if (raw is String) return [raw];
  return null;
}
