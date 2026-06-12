/// Process-wide **sticky default filters** (issue #18).
///
/// `session_configure` writes these; `logs_tail` and `network_list` read them
/// to fill any filter argument the caller omitted. An explicitly-passed
/// argument (even `null`) always wins, so a default never overrides an intent
/// the agent stated this call. The point is to set "I only care about
/// `[EventTracker]` logs and 4xx/5xx requests" once, instead of repeating it
/// on every read.
///
/// In-memory only, reset on process restart. A single global instance: there
/// is one agent driving one server, so per-session scoping would add state
/// without buying anything.
class SessionFilters {
  SessionFilters._();

  static SessionFilters _instance = SessionFilters._();
  static SessionFilters get instance => _instance;

  /// Test seam.
  static void resetForTest() => _instance = SessionFilters._();

  // ----- logs_tail defaults -----
  int? levelMin;
  String? loggerContains;
  List<String>? messageContains;
  String? source;

  // ----- network_list defaults -----
  List<String>? method;
  String? hostContains;
  int? statusMin;
  int? statusMax;

  bool get isEmpty =>
      levelMin == null &&
      loggerContains == null &&
      (messageContains == null || messageContains!.isEmpty) &&
      source == null &&
      (method == null || method!.isEmpty) &&
      hostContains == null &&
      statusMin == null &&
      statusMax == null;

  void clear() {
    levelMin = null;
    loggerContains = null;
    messageContains = null;
    source = null;
    method = null;
    hostContains = null;
    statusMin = null;
    statusMax = null;
  }

  /// The active defaults, omitting unset fields. Used by `session_configure`
  /// to echo state and by reads to report what they inherited.
  Map<String, Object?> toBlock() => {
        if (levelMin != null) 'levelMin': levelMin,
        if (loggerContains != null) 'loggerContains': loggerContains,
        if (messageContains != null && messageContains!.isNotEmpty)
          'messageContains': messageContains,
        if (source != null) 'source': source,
        if (method != null && method!.isNotEmpty) 'method': method,
        if (hostContains != null) 'hostContains': hostContains,
        if (statusMin != null) 'statusMin': statusMin,
        if (statusMax != null) 'statusMax': statusMax,
      };
}
