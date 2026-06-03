/// Single source of truth for the running package version. Read by
/// `lib/src/server.dart` (Implementation), `bin/flutter_network_mcp.dart`
/// (UpdateCheck), and the docs. Must match the `version:` line in
/// `pubspec.yaml` — bump in both places at release time.
const String packageVersion = '0.6.2';
