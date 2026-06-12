import '../storage/capture_writer.dart';
import '../vm/dtd_client.dart';
import '../vm/log_stream.dart';
import '../vm/vm_client.dart';
import 'log_buffer.dart';

/// Process-lifetime singleton owning the DTD connection and exposing
/// backwards-compat getters for the per-attach resources that have moved
/// into the [SessionRegistry].
///
/// **0.6.0-in-progress (Phase 2 of multi-attach refactor):** the per-attach
/// resources — `vm`, `captureWriter`, `logBuffer`, `logStream` — and the
/// per-attach state — `attachedAppName`, `liveSessionId`,
/// `httpProfilingEnabled`, `socketProfilingEnabled`, `lastHttpCursor` —
/// now live on individual [AttachedSession] objects owned by the registry.
/// This class's accessors delegate to `SessionRegistry.instance.soleAttached`
/// so existing tool call sites keep working without modification. Phase 3
/// migrates tools to read the registry directly; Phase 6 deletes this
/// facade entirely.
///
/// DTD client and the history-mode `viewedSessionId` stay here (shared
/// across all attached sessions).
class Session {
  Session._();
  static final Session instance = Session._();

  // === Shared singletons (Phase 2: unchanged) ===

  final DtdClient dtd = DtdClient();

  /// When non-null, query tools (network_list/get/body, socket_list/get,
  /// logs_tail) read from the captures DB for this session instead of the
  /// live VM service. History view is single-pointer by design — opening
  /// 2 history sessions at once is not useful (you're reading the past).
  int? viewedSessionId;

  // === Per-attach resources — delegated to the registry's soleAttached ===
  //
  // When nothing is attached, the getters fall back to never-connected
  // stubs so tools that bare-read (without a prior `isAttached` check)
  // see a graceful "not connected" rather than NPE. After Phase 3 tools
  // route via the registry directly and these getters become unreachable
  // for the live path.

  VmClient get vm =>
      SessionRegistry.instance.soleAttached?.vm ?? _stubVm;
  CaptureWriter get captureWriter =>
      SessionRegistry.instance.soleAttached?.captureWriter ?? _stubCaptureWriter;
  LogBuffer get logBuffer =>
      SessionRegistry.instance.soleAttached?.logBuffer ?? _stubLogBuffer;
  LogStreamSubscriber get logStream =>
      SessionRegistry.instance.soleAttached?.logStream ?? _stubLogStream;

  final VmClient _stubVm = VmClient();
  final CaptureWriter _stubCaptureWriter = CaptureWriter();
  final LogBuffer _stubLogBuffer = LogBuffer();
  final LogStreamSubscriber _stubLogStream = LogStreamSubscriber();

  // === Per-attach state — delegated to the registry's soleAttached ===

  /// Human-readable app name from DTD (e.g. `Flutter - iPhone 17`).
  String? get attachedAppName =>
      SessionRegistry.instance.soleAttached?.appName;

  /// Live capture session id. Returns null when nothing is attached or when
  /// 2+ are attached (the multi-attach case Phase 5 enables — tools should
  /// route via the registry to disambiguate).
  int? get liveSessionId => SessionRegistry.instance.soleAttached?.id;

  bool get httpProfilingEnabled =>
      SessionRegistry.instance.soleAttached?.httpProfilingEnabled ?? false;
  bool get socketProfilingEnabled =>
      SessionRegistry.instance.soleAttached?.socketProfilingEnabled ?? false;

  /// Cursor used by live `network_list` when caller omits `since`. Mutated
  /// by network_list; null when nothing is attached.
  DateTime? get lastHttpCursor =>
      SessionRegistry.instance.soleAttached?.lastHttpCursor;
  set lastHttpCursor(DateTime? v) {
    final s = SessionRegistry.instance.soleAttached;
    if (s != null) s.lastHttpCursor = v;
  }

  // === Derived state ===

  /// True when exactly one session is attached AND its VM is connected
  /// with a resolved isolate. Equivalent to today's semantics for the
  /// single-attach case; Phase 5 reworks for multi-attach.
  bool get isAttached =>
      dtd.isConnected && vm.isConnected && vm.isolateId != null;
  bool get isViewingHistory => viewedSessionId != null;

  /// The session id to read FROM in query tools. Prefers explicit view,
  /// else the (single) live session.
  int? get effectiveSessionId => viewedSessionId ?? liveSessionId;

  /// Tears down every attached session and disconnects DTD. Used by the
  /// failure path of performAttach when no other attachments exist, by
  /// network_detach with `all:true`, and by tests/shutdown.
  ///
  /// Per-session detach lives on [SessionRegistry.detachOne] now; this
  /// remaining method is the "shut everything down" helper.
  Future<void> detach() async {
    await SessionRegistry.instance.detachAll();
    await dtd.disconnect();
    viewedSessionId = null;
  }
}

/// Per-attach record describing one live capture session — owns the VM
/// connection, capture writer (2s polling), log buffer (500-entry ring),
/// and log stream subscriber for that session.
///
/// **Phase 2 status:** the resources are now per-attach (constructed fresh
/// by `network_attach`). Multiple AttachedSessions can coexist in the
/// registry once Phase 5 lifts the single-attach guard.
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
    required this.httpProfilingEnabled,
    required this.socketProfilingEnabled,
    this.lastReattachAt,
    this.previousVmServiceUri,
    this.reattachCount = 0,
  });

  /// DB row id in `sessions` table — the canonical anchor for routing.
  final int id;

  /// Display name from DTD (may collide if you run the same app twice;
  /// `vmServiceUri` is the unique key).
  final String? appName;

  /// Unique attach key — `Map<String, AttachedSession>` is keyed on this.
  final String vmServiceUri;

  final String? isolateId;

  /// Per-session resources. Owned: each attach gets its own instances so
  /// multiple sessions can poll independently.
  final VmClient vm;
  final CaptureWriter captureWriter;
  final LogBuffer logBuffer;
  final LogStreamSubscriber logStream;

  final DateTime attachedAt;

  /// Capture state captured at attach-time. Immutable for the lifetime of
  /// the session (the streams either enabled cleanly or they didn't).
  final bool httpProfilingEnabled;
  final bool socketProfilingEnabled;

  /// Set when this session id was carried across a hot-restart reattach
  /// (issue #16): the wall-clock of the most recent migration, and the VM
  /// service URI it was previously bound to. Null for a fresh attach.
  final DateTime? lastReattachAt;
  final String? previousVmServiceUri;

  /// How many hot restarts this session has survived. Incremented on each
  /// reattach (manual `reattach:true` or the auto-migration watcher), carried
  /// across migrations so it counts the session's whole life, not just the
  /// latest hop. 0 for a session that has never migrated.
  final int reattachCount;

  /// Mutable: updated by network_list when caller omits `since`.
  DateTime? lastHttpCursor;

  /// Live snapshot of every HTTP-profiling isolate the capture writer is
  /// polling for this session. Delegates to the VmClient so the list stays
  /// fresh as the writer discovers newly-spawned isolates (Phase 10).
  /// Returns an empty list when nothing has been discovered yet.
  List<IsolateInfo> get isolates => vm.httpProfilingIsolates;
}

/// Process-lifetime singleton tracking every attached session, keyed by
/// vmServiceUri (the unique attach identifier — appName can collide).
///
/// **Phase 2 status:** the registry now owns per-attach resources. Tools
/// still read via [Session.instance]'s delegated getters; Phase 3 introduces
/// a scope resolver that routes read tools through this registry directly.
///
/// The DTD client is shared across all sessions (one DTD knows about
/// N apps).
class SessionRegistry {
  SessionRegistry._();
  static final SessionRegistry instance = SessionRegistry._();

  /// Shared across all attached sessions (one DTD knows about N apps). Same
  /// instance as `Session.instance.dtd` — Phase 6 removes the duplicate
  /// accessor on Session.
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
  /// session's resources first (today that happens via [detachOne]).
  /// No-op when not present.
  void unregister(String vmServiceUri) {
    _attached.remove(vmServiceUri);
  }

  /// Tears down one attached session's resources (capture writer, log
  /// stream, VM connection) and unregisters it. After this, [attached]
  /// no longer contains the session. Does NOT touch DTD — caller decides
  /// whether to disconnect DTD (typically only when [attachedCount] is
  /// now zero).
  Future<void> detachOne(AttachedSession s) async {
    s.captureWriter.stop();
    await s.logStream.stop();
    await s.vm.disconnect();
    unregister(s.vmServiceUri);
  }

  /// Detaches every attached session. Does NOT disconnect DTD — caller
  /// (typically [Session.detach]) handles that.
  Future<void> detachAll() async {
    // Snapshot the values first since detachOne mutates _attached.
    for (final s in List<AttachedSession>.from(_attached.values)) {
      await detachOne(s);
    }
  }
}
