import 'package:flutter_network_mcp/src/util/http_timing.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';

/// RC1 (agent-UX audit 2026-07-02): durations must measure the EXCHANGE
/// (start → response complete), not the request-upload phase. The old
/// `r.endTime` maths recorded a demonstrably 1.6s request as 186µs, made
/// http_slow unfireable, and fed garbage p50/p95 into every stats tool.
void main() {
  final t0 = DateTime.fromMicrosecondsSinceEpoch(1000000);
  final uploadDone = DateTime.fromMicrosecondsSinceEpoch(1000186);
  final responseDone = DateTime.fromMicrosecondsSinceEpoch(2600000);

  HttpProfileRequest build({
    DateTime? requestEnd,
    HttpProfileResponseData? response,
    HttpProfileRequestData? request,
  }) =>
      HttpProfileRequest(
        id: 'r1',
        isolateId: 'isolates/1',
        method: 'GET',
        uri: Uri.parse('https://api.example.com/slow'),
        events: const [],
        startTime: t0,
        endTime: requestEnd,
        request: request,
        response: response,
      );

  test('completed exchange: end = response.endTime, not request.endTime', () {
    final r = build(
      requestEnd: uploadDone, // upload finished 186µs in — the old bug value
      response: HttpProfileResponseData(
        redirects: const [],
        statusCode: 200,
        startTime: DateTime.fromMicrosecondsSinceEpoch(1100000),
        endTime: responseDone,
      ),
    );
    expect(exchangeEndTime(r), responseDone);
    expect(exchangeDuration(r), const Duration(milliseconds: 1600));
  });

  test('response still streaming: no end, no duration (in-flight)', () {
    final r = build(
      requestEnd: uploadDone,
      response: HttpProfileResponseData(
        redirects: const [],
        statusCode: 200,
        startTime: DateTime.fromMicrosecondsSinceEpoch(1100000),
        // endTime null — body still arriving
      ),
    );
    expect(exchangeEndTime(r), isNull);
    expect(exchangeDuration(r), isNull);
  });

  test('request sent, no response yet: in-flight, not a 0ms exchange', () {
    final r = build(requestEnd: uploadDone);
    expect(exchangeEndTime(r), isNull);
    expect(exchangeDuration(r), isNull);
  });

  test('errored request: request endTime is the best available end', () {
    final r = build(
      requestEnd: uploadDone,
      request: HttpProfileRequestData.buildErrorRequest(
        error: 'SocketException: Connection refused',
      ),
    );
    expect(exchangeEndTime(r), uploadDone);
    expect(exchangeDuration(r), const Duration(microseconds: 186));
  });

  test('truly in-flight request (no endTime at all): null end', () {
    final r = build();
    expect(exchangeEndTime(r), isNull);
  });
}
