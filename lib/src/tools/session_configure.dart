import 'dart:async';

import 'package:dart_mcp/server.dart';

import '../config/body_decryption.dart';
import '../config/session_filters.dart';
import '../state/session.dart';
import '../storage/captures_db.dart';
import '../util/filters.dart';
import 'error_kind.dart';
import 'result.dart';

final sessionConfigureTool = Tool(
  name: 'session_configure',
  description:
      'Set process-wide sticky default filters that logs_tail and '
      'network_list inherit when you omit the matching arg (set levelMin / '
      'messageContains / statusMin once, then read without repeating them). '
      'An arg you pass still wins. Pass null to unset a field, clear:true to '
      'reset all, no args to view. In-memory; resets on restart.',
  inputSchema: Schema.object(
    properties: {
      'levelMin': Schema.int(description: 'Default logs_tail levelMin.'),
      'loggerContains':
          Schema.string(description: 'Default logs_tail loggerContains.'),
      'messageContains': Schema.list(
        description: 'Default logs_tail messageContains (OR-matched list).',
        items: Schema.string(),
      ),
      'source': Schema.string(
        description: 'Default logs_tail source ("logging" | "stdout" | "stderr").',
      ),
      'method': Schema.list(
        description: 'Default network_list HTTP method(s).',
        items: Schema.string(),
      ),
      'hostContains':
          Schema.string(description: 'Default network_list hostContains.'),
      'statusMin': Schema.int(description: 'Default network_list statusMin.'),
      'statusMax': Schema.int(description: 'Default network_list statusMax.'),
      'maxResponseTokens': Schema.int(
        description:
            'Per-response token budget. network_list / logs_tail trim their '
            'arrays to fit (newest-first) and report budget.dropped. Keeps '
            'big reads from flooding the agent context.',
      ),
      'clear': Schema.bool(description: 'Reset ALL sticky defaults to none.'),
      'bodyDecryption': Schema.object(
        description: 'Decrypt app-encrypted HTTP bodies on read and index the '
            'plaintext for search. Kept in this process\'s memory only, never '
            'written to the capture DB; replies show a key fingerprint, never '
            'the key. Replay and export keep the original bytes. '
            '{off:true} turns it off.',
        properties: {
          'algorithm': Schema.string(
              description: 'aes-256-ctr (default) or aes-128-ctr.'),
          'key': Schema.string(description: 'The app\'s key.'),
          'keyEncoding':
              Schema.string(description: 'utf8 (default), hex or base64.'),
          'encoding': Schema.string(
              description: 'How the body holds the payload: hex (default), '
                  'base64 or raw bytes.'),
          'ivMode': Schema.string(
              description: 'prefix (default), suffix, or infused: the IV '
                  'spliced into the payload at ivOffset.'),
          'ivOffset': Schema.int(
              description: 'infused: where the IV starts. Hex: in hex '
                  'characters; base64/raw: in decoded bytes.'),
          'ivLength': Schema.int(
              description: 'IV length in the same unit: 32 hex characters '
                  'or 16 bytes (the default).'),
          'off': Schema.bool(description: 'true turns decryption off.'),
        },
      ),
    },
  ),
);

FutureOr<CallToolResult> sessionConfigure(CallToolRequest request) async {
  final args = request.arguments ?? const <String, Object?>{};
  final sf = SessionFilters.instance;

  // clear runs first, so `clear:true levelMin:1000` resets everything then
  // sets the one field you passed.
  if (args['clear'] == true) sf.clear();

  // Each present key sets (or, with null, unsets) that one default. Absent
  // keys are left unchanged.
  if (args.containsKey('levelMin')) sf.levelMin = args['levelMin'] as int?;
  if (args.containsKey('loggerContains')) {
    sf.loggerContains = args['loggerContains'] as String?;
  }
  if (args.containsKey('messageContains')) {
    sf.messageContains = readStringList(args['messageContains']);
  }
  if (args.containsKey('source')) sf.source = args['source'] as String?;
  if (args.containsKey('method')) sf.method = readStringList(args['method']);
  if (args.containsKey('hostContains')) {
    sf.hostContains = args['hostContains'] as String?;
  }
  if (args.containsKey('statusMin')) sf.statusMin = args['statusMin'] as int?;
  if (args.containsKey('statusMax')) sf.statusMax = args['statusMax'] as int?;
  if (args.containsKey('maxResponseTokens')) {
    sf.maxResponseTokens = args['maxResponseTokens'] as int?;
  }
  if (args['clear'] == true) BodyDecryptionConfig.set(null);

  var reindexed = 0;
  final decryptionArg = args['bodyDecryption'];
  if (decryptionArg is Map && decryptionArg['off'] == true) {
    BodyDecryptionConfig.set(null);
  } else if (decryptionArg != null) {
    final parsed = BodyDecryption.parse(decryptionArg);
    if (parsed.error != null) {
      return errorResult('bodyDecryption: ${parsed.error}',
          kind: ErrorKind.badArgument,
          extra: {
            'nextSteps': const [
              'session_configure bodyDecryption:{key:"<32-char key>", '
                  'encoding:"hex", ivMode:"infused", ivOffset:10, ivLength:32}',
            ],
          });
    }
    BodyDecryptionConfig.set(parsed.config);
    reindexed = _reindexOpenSessions();
  }

  final block = sf.toBlock();
  final summary = sf.isEmpty
      ? 'No sticky default filters set. logs_tail / network_list use only the '
          'args you pass them.'
      : 'Sticky defaults active (${block.keys.join(", ")}). logs_tail / '
          'network_list inherit these when you omit the arg; an arg you pass '
          'still wins for that call.';

  final decryption = BodyDecryptionConfig.active;
  return jsonResult({
    'summary': decryption == null
        ? summary
        : '$summary Body decryption is on (${decryption.algorithm}, key '
            '${decryption.keyFingerprint})'
            '${reindexed > 0 ? '; $reindexed captured request(s) reindexed for search' : ''}.',
    'defaults': block,
    'bodyDecryption': decryption?.toBlock() ?? const {'active': false},
    if (decryption != null)
      'warnings': const [
        'decrypted bodies are returned as plaintext, so they land in this '
            'transcript; turn it off with bodyDecryption:{off:true} when done',
      ],
    'nextSteps': sf.isEmpty
        ? const [
            'session_configure levelMin:1000 messageContains:["[EventTracker]"] to default to those logs',
            'session_configure statusMin:400 to default to HTTP errors only',
          ]
        : const [
            'logs_tail now returns the filtered view without repeating args',
            'session_configure clear:true to drop all sticky defaults',
          ],
  });
}

/// Reindexes the attached and the viewed sessions right away; other sessions reindex on their first network_search.
int _reindexOpenSessions() {
  final ids = <int>{
    for (final s in SessionRegistry.instance.attached.values) s.id,
    if (Session.instance.viewedSessionId != null) Session.instance.viewedSessionId!,
  };
  var n = 0;
  for (final id in ids) {
    try {
      n += CapturesDao().reindexSessionBodies(id);
      BodyDecryptionConfig.reindexedSessions.add(id);
    } catch (_) {/* network_search retries it */}
  }
  return n;
}
