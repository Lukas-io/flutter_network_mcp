import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:dart_mcp/server.dart';

import '../telemetry/path_redactor.dart';
import 'error_kind.dart';
import 'result.dart';

const String _kRepo = 'Lukas-io/flutter_network_mcp';
const String _kIssueNewBase =
    'https://github.com/Lukas-io/flutter_network_mcp/issues/new';

final reportIssueTool = Tool(
  name: 'report_issue',
  description:
      'File a GitHub issue against this MCP from an agent turn. type "bug" '
      '(wrong output / crash) or "ux" (awkward / confusing / slow). Posts via '
      'gh CLI if available, else returns a paste-ready URL. Titles and bodies '
      'are path-redacted before submission.',
  inputSchema: Schema.object(
    properties: {
      'type': Schema.string(
        description: '"bug" or "ux". Picks the matching label + template.',
      ),
      'title': Schema.string(
        description: 'One-line summary. Path-redacted before submission.',
      ),
      'body': Schema.string(
        description:
            'Issue body (markdown): what broke, what you expected, the '
            'failing tool call. Path-redacted.',
      ),
      'auto': Schema.bool(
        description:
            'Try gh issue create (default true); false returns a paste-ready '
            'URL.',
      ),
    },
    required: ['type', 'title', 'body'],
  ),
);

FutureOr<CallToolResult> reportIssue(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final type = args['type'] as String?;
  final titleRaw = args['title'] as String?;
  final bodyRaw = args['body'] as String?;
  final auto = (args['auto'] as bool?) ?? true;

  if (type == null || (type != 'bug' && type != 'ux')) {
    return errorResult(
      'report_issue: `type` must be "bug" or "ux", got "$type".',
      kind: ErrorKind.badArgument,
      extra: const {
        'nextSteps': ['Retry with type:"bug" or type:"ux"'],
      },
    );
  }
  if (titleRaw == null || titleRaw.isEmpty) {
    return errorResult('report_issue: `title` is required.', kind: ErrorKind.badArgument);
  }
  if (bodyRaw == null || bodyRaw.isEmpty) {
    return errorResult('report_issue: `body` is required.', kind: ErrorKind.badArgument);
  }

  final title = redactPath(titleRaw);
  final body = redactPath(bodyRaw);
  final labels = _labelsForType(type);

  if (auto && _isGhInstalled()) {
    try {
      final existing = await _existingLabels();
      var applied = selectApplicableLabels(labels, existing);

      var result = await _ghIssueCreate(title, body, applied);
      if (result.exitCode != 0 &&
          applied.isNotEmpty &&
          isMissingLabelError(result.stderr as String)) {
        applied = const [];
        result = await _ghIssueCreate(title, body, applied);
      }

      if (result.exitCode == 0) {
        final url = (result.stdout as String).trim();
        final dropped = labels.where((l) => !applied.contains(l)).toList();
        return jsonResult({
          'filed': true,
          'method': 'gh-cli',
          'type': type,
          'labels': applied,
          if (dropped.isNotEmpty) 'droppedLabels': dropped,
          'title': title,
          'url': url,
          'nextSteps': [
            'Mention the URL to the user: $url',
            if (dropped.isNotEmpty)
              'Skipped label(s) not present in the repo so they could not '
                  'block filing: ${dropped.join(", ")}',
            'Optionally save a session_note linking to the issue for future continuity',
          ],
        });
      }
      return jsonResult({
        'filed': false,
        'method': 'paste-ready',
        'type': type,
        'labels': labels,
        'title': title,
        'body': body,
        'url': _composeDeepLink(title: title, body: body, labels: labels),
        'warnings': [
          'gh issue create exited ${result.exitCode}: '
              '${(result.stderr as String).trim()}',
        ],
        'nextSteps': const [
          'Open the deep-link URL above; the title + body + labels are '
              'pre-filled',
          'If `gh auth status` shows you\'re logged out, run `gh auth login` '
              'and retry',
        ],
      });
    } on io.ProcessException catch (e) {
      io.stderr.writeln(
        'report_issue: gh CLI invocation failed (${e.message}); falling '
        'back to paste-ready URL.',
      );
    }
  }

  return jsonResult({
    'filed': false,
    'method': 'paste-ready',
    'type': type,
    'labels': labels,
    'title': title,
    'body': body,
    'url': _composeDeepLink(title: title, body: body, labels: labels),
    'nextSteps': const [
      'Tell the user to open the deep-link URL — title + body + labels are '
          'pre-filled',
      'Install `gh` (https://cli.github.com/) + `gh auth login` to enable '
          'one-call filing next time',
    ],
  });
}

/// Labels applied to a filed issue based on [type]. Conservative defaults
/// — the user can re-label in the GitHub UI if they want a different
/// taxonomy.
List<String> _labelsForType(String type) {
  switch (type) {
    case 'bug':
      return const ['bug', 'agent-filed'];
    case 'ux':
      return const ['ux-friction', 'agent-filed'];
    default:
      return const ['agent-filed'];
  }
}

/// Best-effort `gh` install detector. Runs `gh --version` synchronously;
/// success = gh is on PATH. False on any failure (missing binary, OS
/// blocked the spawn, etc.).
bool _isGhInstalled() {
  try {
    final result = io.Process.runSync('gh', ['--version']);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// Runs `gh issue create` against [_kRepo]. The `--label` flag is omitted
/// entirely when [labels] is empty (passing an empty `--label` is itself an
/// error), so callers can request "no labels" cleanly.
Future<io.ProcessResult> _ghIssueCreate(
  String title,
  String body,
  List<String> labels,
) {
  return io.Process.run('gh', [
    'issue',
    'create',
    '--repo',
    _kRepo,
    '--title',
    title,
    '--body',
    body,
    if (labels.isNotEmpty) ...['--label', labels.join(',')],
  ]);
}

/// Best-effort fetch of the repo's existing label names via
/// `gh label list --json name`. Returns null when the lookup fails (gh
/// error, offline, bad JSON) so the caller falls back to its
/// retry-without-labels safety net instead of guessing the label set.
Future<Set<String>?> _existingLabels() async {
  try {
    final r = await io.Process.run('gh', [
      'label',
      'list',
      '--repo',
      _kRepo,
      '--json',
      'name',
      '-L',
      '200',
    ]);
    if (r.exitCode != 0) return null;
    final decoded = jsonDecode(r.stdout as String);
    if (decoded is! List) return null;
    return decoded
        .whereType<Map<String, dynamic>>()
        .map((m) => m['name']?.toString())
        .whereType<String>()
        .toSet();
  } catch (_) {
    return null;
  }
}

/// Keeps only [desired] labels that exist in the repo. When [existing] is
/// null (the label lookup failed) the desired labels pass through unchanged,
/// leaving the create's retry-without-labels path as the safety net. A label
/// the tool injects must never block a valid filing. Public for testing.
List<String> selectApplicableLabels(
  List<String> desired,
  Set<String>? existing,
) {
  if (existing == null) return desired;
  return desired.where(existing.contains).toList();
}

/// True when a `gh issue create` stderr indicates a label could not be
/// attached because it does not exist (so a retry without labels is worth
/// trying). Public for testing.
bool isMissingLabelError(String stderr) {
  final s = stderr.toLowerCase();
  return s.contains('not found') &&
      (s.contains('label') || s.contains('could not add'));
}

/// Builds the GitHub "new issue" deep link with `title=`, `body=`, and
/// `labels=` query parameters URL-encoded. GitHub renders the form with
/// these fields pre-filled.
String _composeDeepLink({
  required String title,
  required String body,
  required List<String> labels,
}) {
  final params = <String, String>{
    'title': title,
    'body': body,
    if (labels.isNotEmpty) 'labels': labels.join(','),
  };
  final query = params.entries
      .map((e) => '${Uri.encodeQueryComponent(e.key)}='
          '${Uri.encodeQueryComponent(e.value)}')
      .join('&');
  return '$_kIssueNewBase?$query';
}

/// Public for testing: lets the unit test verify the URL-encoding logic
/// without going through the full tool handler.
String composeIssueDeepLinkForTest({
  required String title,
  required String body,
  required List<String> labels,
}) =>
    _composeDeepLink(title: title, body: body, labels: labels);

/// Public for testing: same label mapping the tool uses.
List<String> labelsForTypeForTest(String type) => _labelsForType(type);
