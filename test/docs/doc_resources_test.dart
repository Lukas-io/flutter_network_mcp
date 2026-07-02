import 'package:flutter_network_mcp/src/docs/doc_resources.dart';
import 'package:test/test.dart';

/// D6 (audit RC10/F8): the shipped docs must be discoverable as MCP
/// resources so a fresh agent can read the per-tool guides in-band.
void main() {
  test('discovers the tool guides + response contract as resources', () {
    final resources = DocResources.discover();
    // Running from source (dart test), the repo docs/ is present.
    expect(resources, isNotEmpty,
        reason: 'docs/tools/** should resolve when running from source');

    final uris = resources.map((r) => r.uri).toSet();
    expect(uris.any((u) => u.toLowerCase().contains('response_contract')), isTrue,
        reason: 'the response contract must be served');
    expect(
        uris.any((u) => u.startsWith('flutter-network://docs/tools/')), isTrue);
    // The network_query guide the tool description points at must exist.
    expect(
        uris.any((u) => u.contains('network_query.md')), isTrue,
        reason: 'the schema guide referenced by network_query must be served');

    // Every resource points at a real, readable markdown file.
    for (final r in resources.take(5)) {
      expect(r.path, endsWith('.md'));
      expect(r.uri, startsWith('flutter-network://docs/'));
    }
  });
}
