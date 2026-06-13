import 'dart:async';
import 'dart:io' as io;

import 'package:dart_mcp/server.dart';

import '../telemetry/path_redactor.dart';
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
      extra: const {
        'nextSteps': ['Retry with type:"bug" or type:"ux"'],
      },
    );
  }
  if (titleRaw == null || titleRaw.isEmpty) {
    return errorResult('report_issue: `title` is required.');
  }
  if (bodyRaw == null || bodyRaw.isEmpty) {
    return errorResult('report_issue: `body` is required.');
  }

  final title = redactPath(titleRaw);
  final body = redactPath(bodyRaw);
  final labels = _labelsForType(type);

  // gh CLI path. Only attempt when auto=true (default).
  if (auto && _isGhInstalled()) {
    try {
      final result = await io.Process.run('gh', [
        'issue',
        'create',
        '--repo',
        _kRepo,
        '--title',
        title,
        '--body',
        body,
        '--label',
        labels.join(','),
      ]);
      if (result.exitCode == 0) {
        final url = (result.stdout as String).trim();
        return jsonResult({
          'filed': true,
          'method': 'gh-cli',
          'type': type,
          'labels': labels,
          'title': title,
          'url': url,
          'nextSteps': [
            'Mention the URL to the user: $url',
            'Optionally save a session_note linking to the issue for future continuity',
          ],
        });
      }
      // gh ran but errored — fall through to paste-ready with stderr included.
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
      // gh disappeared between the install check and now — fall through.
      io.stderr.writeln(
        'report_issue: gh CLI invocation failed (${e.message}); falling '
        'back to paste-ready URL.',
      );
    }
  }

  // Paste-ready fallback. Always available — works on any machine.
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
