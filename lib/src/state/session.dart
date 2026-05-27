import '../storage/capture_writer.dart';
import '../vm/dtd_client.dart';
import '../vm/log_stream.dart';
import '../vm/vm_client.dart';
import 'log_buffer.dart';

/// Process-lifetime singleton owning the active DTD + VM service connections,
/// the live capture session, and the "viewing" pointer used by query tools.
///
/// **0.7.0-in-progress (Phase 1 of multi-attach refactor):** [SessionRegistry]
/// is being introduced alongside this class. Today the registry is a shadow
/// of [Session.instance] state with at most one entry; Phase 2 moves the
/// per-attach resources (VmClient / CaptureWriter / LogBuffer /
/// LogStreamSubscriber) out of here and into per-session [AttachedSession]
/// objects owned by the registry. Until then [Session.instance] remains the
/// source of truth for everything except the registry's keyed map.
class Session {
  Session._();
  static final Session instance = Session._();

  final DtdClient dtd = DtdClient();
  final VmClient vm = VmClient();
  final LogBuffer logBuffer = LogBuffer();
  final LogStreamSubscriber logStream = LogStreamSubscriber();
  final CaptureWriter captureWriter = CaptureWriter();

  /// Human-readable app name from DTD (e.g. `Flutter - iPhone 17`).
  String? attachedAppName;

  /// Cursor used by live `network_list` when caller omits `since`.
  DateTime? lastHttpCursor;

  bool httpProfilingEnabled = false;
  bool socketProfilingEnabled = false;

  /// Live capture session id (set by network_attach).
  int? liveSessionId;

  /// When non-null, query tools (network_list/get/body, socket_list/get,
  /// logs_tail) read from the captures DB for this session instead of the
  /// live VM service. Capture writer continues to write to [liveSessionId]
  /// regardless.
  int? viewedSessionId;

  bool get isAttached =>
      dtd.isConnected && vm.isConnected && vm.isolateId != null;
  bool get isViewingHistory => viewedSessionId != null;

  /// The session id to read FROM in query tools. Prefers explicit view, else
  /// the live session.
  int? get effectiveSessionId => viewedSessionId ?? liveSessionId;

  Future<void> detach() async {
    // Phase 1: keep [SessionRegistry] consistent. Any caller of detach()
    // — graceful network_detach, force-replace re-attach, or the catch block
    // in performAttach — runs through here, so unregister centrally.
    final stale = SessionRegistry.instance.soleAttached;
    if (stale != null) {
      SessionRegistry.instance.unregister(stale.vmServiceUri);
    }

    captureWriter.stop();
    await logStream.stop();
    await vm.disconnect();
    await dtd.disconnect();
    attachedAppName = null;
    lastHttpCursor = null;
    httpProfilingEnabled = false;
    socketProfilingEnabled = false;
    liveSessionId = null;
    viewedSessionId = null;
  }
}

/// Per-attach record describing one live capture session. Populated by
/// network_attach on success; removed by network_detach (or by
/// [Session.detach] for force-replace / failure cleanup).
///
/// **Phase 1 note:** the per-session resources (vm, captureWriter, logBuffer,
/// logStream) reference the shared instances on [Session.instance] today.
/// Phase 2 of the multi-attach refactor will make each AttachedSession own
/// its own resources so multiple can coexist with independent VM
/// connections + 2-second writer timers.
class AttachedSession {
  AttachedSession({
    required this.id,
    required this.appName,
    required this.vmServiceUri,
    this.isolateId,
    required this.vm,
    required this.captureWriter,
    required this.logBuffer,
    required this.logStream,
    required this.attachedAt,
  });

  /// DB row id in `sessions` table — the canonical anchor for routing.
  final int id;

  /// Display name from DTD (may collide if you run the same app twice;
  /// `vmServiceUri` is the unique key).
  final String? appName;

  /// Unique attach key — `Map<String, AttachedSession>` is keyed on this.
  final String vmServiceUri;

  final String? isolateId;

  /// References shared instances on [Session.instance] in Phase 1;
  /// Phase 2 makes them owned per-session.
  final VmClient vm;
  final CaptureWriter captureWriter;
  final LogBuffer logBuffer;
  final LogStreamSubscriber logStream;

  final DateTime attachedAt;
}

/// Process-lifetime singleton tracking every attached session, keyed by
/// vmServiceUri (the unique attach identifier — appName can collide).
///
/// **Phase 1 status:** wired up by network_attach / network_detach but
/// not yet consulted by read tools. The Phase 3 scope resolver routes every
/// read tool through this registry so multi-attach can disambiguate.
///
/// The DTD client is shared across all sessions (one DTD can know about
/// N apps). VmClient / CaptureWriter / LogBuffer / LogStreamSubscriber
/// move to per-attach ownership in Phase 2.
class SessionRegistry {
  SessionRegistry._();
  static final SessionRegistry instance = SessionRegistry._();

  /// Shared across all attached sessions (one DTD knows about N apps). In
  /// Phase 1 this is the same instance as `Session.instance.dtd`; Phase 6
  /// removes the duplicate accessor on Session.
  DtdClient get dtd => Session.instance.dtd;

  final Map<String, AttachedSession> _attached = {};

  /// Read-only view of attached sessions keyed by vmServiceUri.
  Map<String, AttachedSession> get attached => Map.unmodifiable(_attached);

  int get attachedCount => _attached.length;

  AttachedSession? attachedByUri(String vmServiceUri) =>
      _attached[vmServiceUri];

  AttachedSession? attachedById(int sessionId) {
    for (final s in _attached.values) {
      if (s.id == sessionId) return s;
    }
    return null;
  }

  /// Case-insensitive substring match on `appName`. Empty when no match.
  List<AttachedSession> findByAppName(String contains) {
    final lc = contains.toLowerCase();
    return _attached.values
        .where((s) => (s.appName ?? '').toLowerCase().contains(lc))
        .toList();
  }

  /// Returns the single attached session iff exactly one is attached.
  /// Used by the Phase 3 scope resolver as the auto-resolve default when
  /// no `sessionId` / `appNameContains` arg is passed.
  AttachedSession? get soleAttached =>
      _attached.length == 1 ? _attached.values.first : null;

  /// Adds an attached session. Throws [StateError] when a session for the
  /// same vmServiceUri is already registered.
  void register(AttachedSession session) {
    if (_attached.containsKey(session.vmServiceUri)) {
      throw StateError(
        'Already attached to ${session.vmServiceUri} '
        '(session id ${_attached[session.vmServiceUri]!.id}).',
      );
    }
    _attached[session.vmServiceUri] = session;
  }

  /// Removes the session matching [vmServiceUri]. Caller tears down the
  /// session's resources first (today that happens via [Session.detach]).
  /// No-op when not present.
  void unregister(String vmServiceUri) {
    _attached.remove(vmServiceUri);
  }
}
