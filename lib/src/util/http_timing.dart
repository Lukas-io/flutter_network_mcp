import 'package:vm_service/vm_service.dart';

/// When did this HTTP exchange actually END? (RC1, agent-UX audit 2026-07-02)
///
/// `HttpProfileRequestRef.endTime` is the end of the REQUEST phase — the
/// upload. dart:io stamps it when the request body finishes sending (hence
/// the adjacent getter `isRequestComplete`), which for a typical GET is
/// microseconds after start. Treating it as the exchange end made every
/// captured duration ~0 ms, made the `http_slow` alert rule unfireable, and
/// fed garbage p50/p95 into summarize / report / diff_session.
///
/// The exchange truly ends when the response completes (`response.endTime`).
/// An errored request never gets one — there, `endTime` (the error time) is
/// the best available end. A request whose response is still streaming has
/// no end yet: callers receive null and must treat it as in-flight, never
/// as 0 ms.
DateTime? exchangeEndTime(HttpProfileRequestRef r) {
  final responseEnd = r.response?.endTime;
  if (responseEnd != null) return responseEnd;
  final erred =
      (r.request?.hasError ?? false) || (r.response?.hasError ?? false);
  if (erred) return r.endTime;
  return null;
}

/// [exchangeEndTime] minus start; null while the exchange is in flight.
Duration? exchangeDuration(HttpProfileRequestRef r) =>
    exchangeEndTime(r)?.difference(r.startTime);
