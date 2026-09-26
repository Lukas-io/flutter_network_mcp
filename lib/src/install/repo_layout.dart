/// Where glint_network lives inside the glint repository; `dart pub global activate -s git` takes it as `--git-path`.
const String packageGitPath = 'packages/glint_network';

/// Pub names its git checkouts `<repo>-<commit>`, so the glint repository lands in `<pub_cache>/git/glint-<commit>`.
const String repoCheckoutPrefix = 'glint-';

/// This package's pub name; the one-time bridge release on the old repository ships the same code as `flutter_network_mcp`.
const String packageName = 'flutter_network_mcp';

/// The pub package name and command before the rename.
const String legacyName = 'flutter_network_mcp';
