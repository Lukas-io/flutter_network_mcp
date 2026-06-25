import 'package:flutter_network_mcp/src/tools/network_list.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';

/// #41: a single in-flight request in an error state (e.g. a DNS failure)
/// must not make the live read throw. Before the fix, reading the
/// error-guarded `contentLength` getter on an errored request threw
/// HttpProfileRequestError, which aborted the entire network_list read.
void main() {
  HttpProfileRequest erroredRequest() => HttpProfileRequest(
        id: 'req-err-1',
        isolateId: 'isolates/1',
        method: 'GET',
        uri: Uri.parse('https://development.example.com/api/orders'),
        events: const [],
        startTime: DateTime.fromMicrosecondsSinceEpoch(1000),
        request: HttpProfileRequestData.buildErrorRequest(
          error: 'SocketException: Failed host lookup: '
              "'development.example.com'",
        ),
      );

  HttpProfileRequest cleanRequest() => HttpProfileRequest(
        id: 'req-ok-1',
        isolateId: 'isolates/1',
        method: 'POST',
        uri: Uri.parse('https://api.example.com/login'),
        events: const [],
        startTime: DateTime.fromMicrosecondsSinceEpoch(2000),
        endTime: DateTime.fromMicrosecondsSinceEpoch(3000),
        request: HttpProfileRequestData.buildSuccessfulRequest(
          cookies: const [],
          contentLength: 42,
        ),
      );

  test('errored in-flight request yields a row instead of throwing', () {
    late Map<String, Object?> row;
    expect(() => row = liveSummary(erroredRequest()), returnsNormally);
    expect(row['id'], 'req-err-1');
    expect(row['method'], 'GET');
    expect(row['uri'], 'https://development.example.com/api/orders');
    expect(row['hasError'], isTrue);
    expect(row['error'], contains('Failed host lookup'));
    // The throwing getter must not have been read for an errored request.
    expect(row.containsKey('requestContentLength'), isFalse);
  });

  test('clean request still surfaces contentLength and no error flag', () {
    final row = liveSummary(cleanRequest());
    expect(row['hasError'], isNull);
    expect(row['requestContentLength'], 42);
    expect(row['durationMs'], 1);
  });
}
