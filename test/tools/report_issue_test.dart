import 'package:flutter_network_mcp/src/tools/report_issue.dart';
import 'package:test/test.dart';

void main() {
  group('labelsForType', () {
    test('bug → [bug, agent-filed]', () {
      expect(labelsForTypeForTest('bug'), ['bug', 'agent-filed']);
    });

    test('ux → [ux-friction, agent-filed]', () {
      expect(labelsForTypeForTest('ux'), ['ux-friction', 'agent-filed']);
    });

    test('unknown type → [agent-filed]', () {
      expect(labelsForTypeForTest('weird'), ['agent-filed']);
    });
  });

  group('selectApplicableLabels (#42)', () {
    test('keeps only labels the repo actually has', () {
      // Real case: repo has `bug` but not `agent-filed`.
      expect(
        selectApplicableLabels(['bug', 'agent-filed'], {'bug', 'enhancement'}),
        ['bug'],
      );
    });

    test('drops all when none exist (filing proceeds label-less)', () {
      expect(
        selectApplicableLabels(['ux-friction', 'agent-filed'], {'bug'}),
        isEmpty,
      );
    });

    test('null existing (lookup failed) passes desired through unchanged', () {
      expect(
        selectApplicableLabels(['bug', 'agent-filed'], null),
        ['bug', 'agent-filed'],
      );
    });

    test('preserves desired order', () {
      expect(
        selectApplicableLabels(['a', 'b', 'c'], {'c', 'a', 'b'}),
        ['a', 'b', 'c'],
      );
    });
  });

  group('isMissingLabelError (#42)', () {
    test('detects the real gh "label not found" stderr', () {
      expect(
        isMissingLabelError("could not add label: 'agent-filed' not found"),
        isTrue,
      );
    });

    test('case-insensitive', () {
      expect(isMissingLabelError("Label 'X' NOT FOUND"), isTrue);
    });

    test('unrelated errors do not trigger a label retry', () {
      expect(isMissingLabelError('HTTP 401: Bad credentials'), isFalse);
      expect(isMissingLabelError('could not connect to host'), isFalse);
    });
  });

  group('composeIssueDeepLink', () {
    test('basic title + body + labels url-encoded into query params', () {
      final url = composeIssueDeepLinkForTest(
        title: 'crash on attach',
        body: 'StateError thrown',
        labels: ['bug', 'agent-filed'],
      );
      expect(
        url,
        startsWith('https://github.com/Lukas-io/flutter_network_mcp/issues/new?'),
      );
      expect(url, contains('title=crash+on+attach'));
      expect(url, contains('body=StateError+thrown'));
      expect(url, contains('labels=bug%2Cagent-filed'));
    });

    test('special characters encoded safely', () {
      final url = composeIssueDeepLinkForTest(
        title: 'token & query: failed',
        body: '```dart\nthrow Error("oops");\n```',
        labels: ['bug'],
      );
      expect(url, contains('token+%26+query'));
      expect(url, contains('%3A'),
          reason: ': must be percent-encoded');
      expect(url, contains('%60%60%60'),
          reason: 'triple backtick must be percent-encoded');
      expect(url, contains('throw+Error%28%22oops%22%29%3B'));
    });

    test('empty labels list omits labels param', () {
      final url = composeIssueDeepLinkForTest(
        title: 't',
        body: 'b',
        labels: [],
      );
      expect(url, isNot(contains('labels=')));
      expect(url, contains('title=t'));
    });

    test('newlines in body encoded as %0A', () {
      final url = composeIssueDeepLinkForTest(
        title: 't',
        body: 'line 1\nline 2',
        labels: [],
      );
      expect(url, contains('%0A'));
    });
  });
}
