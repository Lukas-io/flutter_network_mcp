/// One spelling per VM service, `http(s)://host:port/<auth token>/`: DTD lists `ws://…/ws`, `flutter run` prints `http://…/`, and both name the same VM.
String canonicalVmServiceUri(String raw) {
  final trimmed = raw.trim();
  final u = Uri.tryParse(trimmed);
  if (u == null || u.host.isEmpty) return trimmed;
  final scheme = switch (u.scheme) {
    'ws' => 'http',
    'wss' => 'https',
    final s => s,
  };
  final segments = [...u.pathSegments.where((s) => s.isNotEmpty)];
  if (segments.isNotEmpty && segments.last == 'ws') segments.removeLast();
  final path = segments.isEmpty ? '/' : '/${segments.join('/')}/';
  return '$scheme://${u.host}${u.hasPort ? ':${u.port}' : ''}$path';
}
