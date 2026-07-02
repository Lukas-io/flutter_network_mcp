import 'dart:io' as io;

import 'package:path/path.dart' as p;

/// D6 (audit RC10/F8): the deep per-tool guides and the response contract
/// live under `docs/` in the repo, and every tool description points at
/// them ("see docs/tools/..."). But a fresh agent has no checkout — so
/// those pointers were dead ends, and `network_query`'s 53% error rate
/// traced straight to an unreachable schema doc. This module locates the
/// shipped `docs/` tree and exposes each file as an MCP resource under
/// `flutter-network://docs/...`, making the guidance in-band.
class DocResources {
  /// Resolves the repo `docs/` directory. The package is installed via
  /// `dart pub global activate -sgit`, so the FULL git checkout (docs
  /// included) is always present in pub-cache — for both the JIT snapshot
  /// and the AOT install. Mirrors install.dart's `_resolveSourcePath`
  /// ladder: Platform.script when it's a `.dart` file (running from
  /// source), else the newest `<pub_cache>/git/flutter_network_mcp-*`.
  static io.Directory? resolveDocsDir() {
    final script = io.Platform.script.toFilePath();
    if (script.endsWith('.dart')) {
      // .../<root>/bin/flutter_network_mcp.dart -> <root>/docs
      final root = p.dirname(p.dirname(script));
      final docs = io.Directory(p.join(root, 'docs'));
      if (docs.existsSync()) return docs;
    }
    final cache = _pubCacheDir();
    if (cache == null) return null;
    final gitDir = io.Directory(p.join(cache, 'git'));
    if (!gitDir.existsSync()) return null;
    io.Directory? newest;
    var newestStamp = DateTime.fromMillisecondsSinceEpoch(0);
    for (final entity in gitDir.listSync()) {
      if (entity is! io.Directory) continue;
      if (!p.basename(entity.path).startsWith('flutter_network_mcp')) continue;
      final docs = io.Directory(p.join(entity.path, 'docs'));
      if (!docs.existsSync()) continue;
      final stamp = docs.statSync().modified;
      if (stamp.isAfter(newestStamp)) {
        newestStamp = stamp;
        newest = docs;
      }
    }
    return newest;
  }

  /// One registerable resource: its `flutter-network://` URI, a display
  /// name, and the absolute file path to read on demand.
  static List<DocResource> discover() {
    final docsDir = resolveDocsDir();
    if (docsDir == null) return const [];
    final out = <DocResource>[];
    for (final entity in docsDir.listSync(recursive: true)) {
      if (entity is! io.File) continue;
      if (!entity.path.endsWith('.md')) continue;
      final rel = p.relative(entity.path, from: docsDir.path);
      // Only ship the agent-facing guides + the response contract, not
      // maintainer/internal docs.
      final isToolGuide = rel.startsWith('tools${p.separator}');
      final isContract = rel == 'RESPONSE_CONTRACT.md';
      if (!isToolGuide && !isContract) continue;
      final uriPath = rel.split(p.separator).join('/');
      out.add(DocResource(
        uri: 'flutter-network://docs/$uriPath',
        name: uriPath,
        path: entity.path,
      ));
    }
    out.sort((a, b) => a.uri.compareTo(b.uri));
    return out;
  }

  static String? _pubCacheDir() {
    final env = io.Platform.environment;
    final explicit = env['PUB_CACHE'];
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final home = env['HOME'] ?? env['USERPROFILE'];
    if (home == null) return null;
    return p.join(home, '.pub-cache');
  }
}

class DocResource {
  DocResource({required this.uri, required this.name, required this.path});
  final String uri;
  final String name;
  final String path;
}
