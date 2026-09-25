import 'package:flutter_network_mcp/src/telemetry/path_redactor.dart';
import 'package:flutter_network_mcp/src/util/secret_redactor.dart';
import 'package:test/test.dart';

void main() {
  group('redactPath', () {
    test('empty input passes through', () {
      expect(redactPath(''), '');
    });

    test('package: URIs untouched (already safe)', () {
      const input =
          '#0 SceneReader.readSummary (package:glint/src/perception/scene_reader.dart:42)';
      expect(redactPath(input), input);
    });

    test('a project path keeps only what follows lib/', () {
      const input =
          '/Users/lukasio/StudioProjects/some_client_app/lib/main.dart';
      expect(redactPath(input, home: ''), '<project>/lib/main.dart');
    });

    test('Linux and root homes are covered', () {
      expect(redactPath('/home/runner/work/app/app/test/x_test.dart', home: ''),
          '<project>/test/x_test.dart');
      expect(redactPath('/root/.pub-cache/x', home: ''), '<home>/.pub-cache/x');
    });

    test('an unusual home is redacted through the environment value', () {
      expect(
          redactPath('/var/builder/code/app/lib/a.dart', home: '/var/builder'),
          '<project>/lib/a.dart');
    });

    test('a home path outside a project keeps its subpath', () {
      expect(redactPath('/Users/lukasio/Documents/notes.txt', home: ''),
          '<home>/Documents/notes.txt');
    });

    test('different usernames produce the same redaction', () {
      const a = '/Users/alice/code/app/lib/main.dart';
      const b = '/Users/bob/code/app/lib/main.dart';
      expect(redactPath(a, home: ''), redactPath(b, home: ''));
    });

    test('Windows project path collapses', () {
      const input = r'C:\Users\lukasio\code\some_app\lib\main.dart';
      expect(redactPath(input, home: ''), r'<project>\lib\main.dart');
    });

    test('idempotent', () {
      const input = '/Users/lukasio/code/x/lib/main.dart';
      final once = redactPath(input, home: '');
      expect(redactPath(once, home: ''), once);
    });

    test('paths without a home stay untouched', () {
      const input = '#0 main (file:///some/system/path/dart.dart:1:1)';
      expect(redactPath(input, home: ''), input);
    });
  });

  group('redactSecrets', () {
    test('masks bearer tokens, JWTs, assignments and long hex keys', () {
      const jwt =
          'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U';
      final out = redactSecrets(
        'Authorization: Bearer abcdef1234567890 token=$jwt '
        'password: hunter2 api_key="sk_live_123456" '
        'sha 0123456789abcdef0123456789abcdef01234567',
      );
      expect(out, isNot(contains('abcdef1234567890')));
      expect(out, isNot(contains('hunter2')));
      expect(out, isNot(contains('sk_live_123456')));
      expect(out, isNot(contains('eyJhbGci')));
      expect(out, isNot(contains('0123456789abcdef0123')));
      expect(out, contains('Bearer <redacted>'));
      expect(out, contains('password: <redacted>'));
    });

    test('ordinary prose is untouched', () {
      const input = 'Tapped the sign in button; the token list stayed empty.';
      expect(redactSecrets(input), input);
    });
  });

  group('redactStackHead', () {
    test('empty trace returns empty list', () {
      expect(redactStackHead(StackTrace.empty), isEmpty);
    });

    test('caps at maxFrames', () {
      final lines = [
        for (var i = 0; i < 20; i++)
          '#$i frameAt$i (package:foo/bar.dart:$i:5)',
      ].join('\n');
      final out = redactStackHead(StackTrace.fromString(lines), maxFrames: 5);
      expect(out, hasLength(5));
      expect(out.first, startsWith('#0 frameAt0'));
      expect(out.last, startsWith('#4 frameAt4'));
    });

    test('redacts home paths in each frame', () {
      final stack = StackTrace.fromString(
        '#0 main (/Users/lukasio/code/x/lib/main.dart:1:1)\n'
        '#1 _other (/home/ci/app/lib/util.dart:5:10)',
      );
      final out = redactStackHead(stack);
      expect(out[0], contains('<project>/lib/main.dart'));
      expect(out[1], contains('<project>/lib/util.dart'));
      expect(out.any((s) => s.contains('lukasio')), isFalse);
    });
  });
}
