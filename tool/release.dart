import 'dart:io';

/// Release helper: `prepare <x.y.z>` bumps versions and dates the changelog on release/v<x.y.z>, `tag` tags the merged release, `notes <x.y.z>` prints its changelog section.
const defaultBranch = 'master';

/// Files holding the version, with the pattern whose first group is the version.
final versionFiles = <String, RegExp>{
  'pubspec.yaml': RegExp(r'^version: (\S+)$', multiLine: true),
  'lib/src/version.dart': RegExp(r"^const String packageVersion = '([^']+)';$", multiLine: true),
};

Future<void> main(List<String> args) async {
  if (args.isEmpty) _fail('usage: prepare <x.y.z> | tag | notes <x.y.z>');
  switch (args.first) {
    case 'prepare' when args.length == 2:
      await _prepare(args[1]);
    case 'tag':
      await _tag();
    case 'notes' when args.length == 2:
      stdout.write(changelogSection(File('CHANGELOG.md').readAsStringSync(), args[1]) ??
          _fail('CHANGELOG.md has no section for ${args[1]}'));
    default:
      _fail('usage: prepare <x.y.z> | tag | notes <x.y.z>');
  }
}

Future<void> _prepare(String version) async {
  if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version)) _fail('version must look like 1.2.3');
  await _requireCleanDefaultBranch();
  final current = currentVersion();
  if (!isNewer(version, current)) _fail('$version is not newer than $current');
  final changelog = File('CHANGELOG.md');
  final dated = datedChangelog(changelog.readAsStringSync(), version, DateTime.now());
  if (dated == null) _fail('CHANGELOG.md has no entries under ## [Unreleased]');
  await _git(['checkout', '-b', 'release/v$version']);
  for (final entry in versionFiles.entries) {
    final file = File(entry.key);
    file.writeAsStringSync(file.readAsStringSync().replaceFirstMapped(
        entry.value, (m) => m[0]!.replaceFirst(m[1]!, version)));
  }
  changelog.writeAsStringSync(dated);
  await _git(['add', 'CHANGELOG.md', ...versionFiles.keys]);
  await _git(['commit', '-m', 'Release $version']);
  stdout.writeln('Committed "Release $version" on release/v$version. Open a PR; after it merges, run: dart run tool/release.dart tag');
}

Future<void> _tag() async {
  await _requireCleanDefaultBranch();
  final version = currentVersion();
  if (changelogSection(File('CHANGELOG.md').readAsStringSync(), version) == null) {
    _fail('CHANGELOG.md has no section for $version; run prepare first');
  }
  final existing = await Process.run('git', ['tag', '--list', 'v$version']);
  if ((existing.stdout as String).trim().isNotEmpty) _fail('tag v$version already exists');
  await _git(['tag', '-a', 'v$version', '-m', 'Release $version']);
  await _git(['push', 'origin', 'v$version']);
  stdout.writeln('Pushed v$version; the release workflow publishes the GitHub Release.');
}

/// The version every version file agrees on.
String currentVersion() {
  final found = {
    for (final entry in versionFiles.entries)
      entry.key: entry.value.firstMatch(File(entry.key).readAsStringSync())?[1],
  };
  final distinct = found.values.toSet();
  if (distinct.length != 1 || distinct.first == null) _fail('version files disagree: $found');
  return distinct.first!;
}

/// True when [a] is a higher semver triple than [b].
bool isNewer(String a, String b) {
  final x = a.split('.').map(int.parse).toList();
  final y = b.split('.').map(int.parse).toList();
  for (var i = 0; i < 3; i++) {
    if (x[i] != y[i]) return x[i] > y[i];
  }
  return false;
}

/// The changelog with the Unreleased entries moved under a dated heading for [version], and an empty Unreleased above it; null when there is nothing unreleased.
String? datedChangelog(String text, String version, DateTime date) {
  final header = RegExp(r'^## \[Unreleased\]\s*$', multiLine: true).firstMatch(text);
  if (header == null) return null;
  final next = RegExp(r'^## \[', multiLine: true).firstMatch(text.substring(header.end));
  final body = next == null ? text.substring(header.end) : text.substring(header.end, header.end + next.start);
  if (body.trim().isEmpty) return null;
  final day = date.toIso8601String().substring(0, 10);
  return '${text.substring(0, header.start)}## [Unreleased]\n\n## [$version] - $day\n'
      '${text.substring(header.end)}';
}

/// The body of the `## [version]` section, without its heading; null when there is none.
String? changelogSection(String text, String version) {
  final header = RegExp('^## \\[${RegExp.escape(version)}\\].*\$', multiLine: true).firstMatch(text);
  if (header == null) return null;
  final rest = text.substring(header.end);
  final next = RegExp(r'^## \[', multiLine: true).firstMatch(rest);
  final body = (next == null ? rest : rest.substring(0, next.start)).trim();
  return body.isEmpty ? null : '$body\n';
}

Future<void> _requireCleanDefaultBranch() async {
  final branch = (await Process.run('git', ['rev-parse', '--abbrev-ref', 'HEAD'])).stdout.toString().trim();
  if (branch != defaultBranch) _fail('run this on $defaultBranch (on $branch)');
  final status = (await Process.run('git', ['status', '--porcelain', '--untracked-files=no'])).stdout.toString();
  if (status.trim().isNotEmpty) _fail('commit or stash your changes first');
  await _git(['pull', '--ff-only']);
}

Future<void> _git(List<String> args) async {
  final r = await Process.run('git', args);
  if (r.exitCode != 0) _fail('git ${args.join(' ')} failed: ${r.stderr}');
}

Never _fail(String message) {
  stderr.writeln('release: $message');
  exit(1);
}
