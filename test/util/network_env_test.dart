import 'package:flutter_network_mcp/src/util/network_env.dart';
import 'package:test/test.dart';

void main() {
  test('a legacy FLUTTER_NETWORK_MCP_ variable is readable under its GLINT_NETWORK_ name', () {
    final env = withLegacyNames({'FLUTTER_NETWORK_MCP_TELEMETRY': 'on', 'HOME': '/h'});
    expect(env['GLINT_NETWORK_TELEMETRY'], 'on');
    expect(env['HOME'], '/h');
  });

  test('the new name wins when both are set', () {
    final env = withLegacyNames({
      'FLUTTER_NETWORK_MCP_MAX_ATTACH': '2',
      'GLINT_NETWORK_MAX_ATTACH': '5',
    });
    expect(env['GLINT_NETWORK_MAX_ATTACH'], '5');
  });
}
