import 'package:flutter_network_mcp/src/util/http_classify.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';

/// D7 (audit F21/F30): classify at ingestion. A successful WebSocket
/// upgrade must not read as a failed request, and alert titles must not
/// carry the meaningless `:0` port.
void main() {
  HttpProfileRequest ws({required bool erroredResponse}) => HttpProfileRequest(
        id: 'ws1',
        isolateId: 'isolates/1',
        method: 'GET',
        uri: Uri.parse('wss://host/socket.io/'),
        events: const [],
        startTime: DateTime.fromMicrosecondsSinceEpoch(1000),
        response: erroredResponse
            ? HttpProfileResponseData(redirects: const [], error: 'Socket has been detached')
            : HttpProfileResponseData(
                redirects: const [], statusCode: 101,
                reasonPhrase: 'Switching Protocols'),
      );

  test('101 with reason "Switching Protocols" is a WS upgrade', () {
    expect(isWebSocketUpgrade(ws(erroredResponse: false)), isTrue);
  });

  test('an errored 101 upgrade is a benign upgrade error, not a failure', () {
    final r = HttpProfileRequest(
      id: 'ws2',
      isolateId: 'isolates/1',
      method: 'GET',
      uri: Uri.parse('wss://host/ws'),
      events: const [],
      startTime: DateTime.fromMicrosecondsSinceEpoch(1000),
      response: HttpProfileResponseData(
        redirects: const [],
        statusCode: 101,
        reasonPhrase: 'Switching Protocols',
        error: 'Socket has been detached',
      ),
    );
    expect(isBenignUpgradeError(r), isTrue);
  });

  test('a real errored request is NOT a benign upgrade', () {
    final r = HttpProfileRequest(
      id: 'e1',
      isolateId: 'isolates/1',
      method: 'GET',
      uri: Uri.parse('https://host/api'),
      events: const [],
      startTime: DateTime.fromMicrosecondsSinceEpoch(1000),
      request:
          HttpProfileRequestData.buildErrorRequest(error: 'Connection refused'),
    );
    expect(isBenignUpgradeError(r), isFalse);
  });

  group('displayUrl strips :0 and default ports (F30)', () {
    test(':0 port removed', () {
      expect(displayUrl(Uri.parse('https://host:0/socket.io/')),
          'https://host/socket.io/');
    });
    test('explicit default https port removed', () {
      expect(displayUrl(Uri.parse('https://host:443/x')), 'https://host/x');
    });
    test('non-default port kept', () {
      expect(displayUrl(Uri.parse('http://host:8086/api')),
          'http://host:8086/api');
    });
  });
}
