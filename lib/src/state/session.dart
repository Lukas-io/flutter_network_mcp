import '../storage/capture_writer.dart';
import '../vm/dtd_client.dart';
import '../vm/log_stream.dart';
import '../vm/vm_client.dart';
import 'log_buffer.dart';

/// Process-lifetime singleton owning the active DTD + VM service connections,
/// the live capture session, and the "viewing" pointer used by query tools.
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
