import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'capture_buffer.dart';
import 'realtime_extension.dart';
import 'ws_frame.dart';

/// Installs the runtime hooks that capture WebSocket frames. Call once, in
/// debug mode, at the top of `main()`:
///
/// ```dart
/// void main() {
///   if (kDebugMode) FlutterNetworkMcpHooks.install();
///   runApp(const MyApp());
/// }
/// ```
///
/// `WebSocket.connect` (and `dart:io`-based WebSocket libraries) resolve their
/// `HttpClient` through [HttpOverrides], upgrade via HTTP, then call
/// `HttpClientResponse.detachSocket()` to get the raw post-upgrade socket. We
/// wrap that chain and tee the detached socket's bytes into per-direction
/// frame decoders. (We can't wrap at the `dart:io` socket layer: `WebSocket`
/// uses `socketStartConnect`, whose `ConnectionTask` is a `final` class.)
class FlutterNetworkMcpHooks {
  static HttpOverrides? _previous;
  static bool _installed = false;

  static void install() {
    if (_installed) return;
    _previous = HttpOverrides.current;
    HttpOverrides.global = _HooksHttpOverrides(_previous);
    _installed = true;
    RealtimeCapture.instance.installed = true;
    // Surface the capture buffer to the MCP over the VM service.
    RealtimeExtension.register();
  }

  /// Restores the previous [HttpOverrides]. Mainly for tests.
  static void uninstall() {
    if (!_installed) return;
    HttpOverrides.global = _previous;
    _previous = null;
    _installed = false;
    RealtimeCapture.instance.installed = false;
  }
}

base class _HooksHttpOverrides extends HttpOverrides {
  _HooksHttpOverrides(this._prev);
  final HttpOverrides? _prev;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final inner =
        _prev?.createHttpClient(context) ?? super.createHttpClient(context);
    return _WrappedHttpClient(inner);
  }

  @override
  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) {
    return _prev?.findProxyFromEnvironment(url, environment) ??
        super.findProxyFromEnvironment(url, environment);
  }
}

/// Captures one detached WebSocket socket. Outbound = client -> server (masked
/// frames); inbound = server -> client (unmasked). Each direction decodes
/// frames, reassembles fragmented messages, and (when permessage-deflate is in
/// use) inflates them, before recording one row per logical message.
class _SocketCapture {
  _SocketCapture(int connectionId)
      : _outAsm = _MessageAssembler(connectionId, true),
        _inAsm = _MessageAssembler(connectionId, false);

  final WsFrameDecoder _outDec = WsFrameDecoder();
  final WsFrameDecoder _inDec = WsFrameDecoder();
  final _MessageAssembler _outAsm;
  final _MessageAssembler _inAsm;

  void onOutbound(List<int> data) {
    try {
      for (final f in _outDec.addBytes(data)) {
        _outAsm.onFrame(f);
      }
    } catch (_) {/* capture must never break the app */}
  }

  void onInbound(List<int> data) {
    try {
      for (final f in _inDec.addBytes(data)) {
        _inAsm.onFrame(f);
      }
    } catch (_) {/* capture must never break the app */}
  }
}

/// Reassembles fragmented frames into messages and inflates permessage-deflate
/// (RFC 7692) for one direction. With context takeover (the default) the
/// inflate filter persists across messages, so it is created once and reused.
class _MessageAssembler {
  _MessageAssembler(this._connectionId, this._outbound);
  final int _connectionId;
  final bool _outbound;

  RawZLibFilter? _inflater;
  int? _opcode;
  bool _compressed = false;
  final BytesBuilder _payload = BytesBuilder();

  void onFrame(WsFrame f) {
    if (f.isControl) {
      // Record a close payload; drop ping/pong keepalive noise.
      if (f.opcode == WsOpcode.close) {
        _record(WsOpcode.close, f.payload, false);
      }
      return;
    }
    // Data frame: a text/binary start, or a continuation.
    if (f.opcode != WsOpcode.continuation) {
      _opcode = f.opcode;
      _compressed = f.rsv1; // RSV1 on the FIRST frame marks a compressed msg
      _payload.clear();
    }
    _payload.add(f.payload);
    if (!f.fin) return;

    final raw = _payload.takeBytes();
    final op = _opcode ?? WsOpcode.binary;
    if (_compressed) {
      _record(op, _inflate(raw), true);
    } else {
      _record(op, raw, false);
    }
    _opcode = null;
    _compressed = false;
  }

  Uint8List _inflate(Uint8List deflated) {
    final filter = _inflater ??= RawZLibFilter.inflateFilter(raw: true);
    // RFC 7692: append the empty-block trailer the sender stripped.
    final input = <int>[...deflated, 0x00, 0x00, 0xFF, 0xFF];
    filter.process(input, 0, input.length);
    final out = BytesBuilder();
    List<int>? chunk;
    while ((chunk = filter.processed(flush: true)) != null) {
      out.add(chunk!);
    }
    return out.takeBytes();
  }

  void _record(int opcode, Uint8List payload, bool wasCompressed) {
    RealtimeCapture.instance.recordMessage(
      connectionId: _connectionId,
      outbound: _outbound,
      opcode: opcode,
      payload: payload,
      wasCompressed: wasCompressed,
    );
  }
}

class _WrappedHttpClient implements HttpClient {
  _WrappedHttpClient(this._inner);
  final HttpClient _inner;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    return _WrappedRequest(await _inner.openUrl(method, url), url);
  }

  @override
  Future<HttpClientRequest> open(
      String method, String host, int port, String path) async {
    final req = await _inner.open(method, host, port, path);
    return _WrappedRequest(req, req.uri);
  }

  // Convenience verbs delegate through openUrl so WS (which uses openUrl) and
  // everything else share one wrap point.
  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);
  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      open('GET', host, port, path);
  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('POST', url);
  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      open('POST', host, port, path);
  @override
  Future<HttpClientRequest> putUrl(Uri url) => openUrl('PUT', url);
  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      open('PUT', host, port, path);
  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => openUrl('DELETE', url);
  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      open('DELETE', host, port, path);
  @override
  Future<HttpClientRequest> patchUrl(Uri url) => openUrl('PATCH', url);
  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      open('PATCH', host, port, path);
  @override
  Future<HttpClientRequest> headUrl(Uri url) => openUrl('HEAD', url);
  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      open('HEAD', host, port, path);

  @override
  bool get autoUncompress => _inner.autoUncompress;
  @override
  set autoUncompress(bool v) => _inner.autoUncompress = v;
  @override
  Duration? get connectionTimeout => _inner.connectionTimeout;
  @override
  set connectionTimeout(Duration? v) => _inner.connectionTimeout = v;
  @override
  Duration get idleTimeout => _inner.idleTimeout;
  @override
  set idleTimeout(Duration v) => _inner.idleTimeout = v;
  @override
  int? get maxConnectionsPerHost => _inner.maxConnectionsPerHost;
  @override
  set maxConnectionsPerHost(int? v) => _inner.maxConnectionsPerHost = v;
  @override
  String? get userAgent => _inner.userAgent;
  @override
  set userAgent(String? v) => _inner.userAgent = v;

  @override
  set authenticate(
          Future<bool> Function(Uri url, String scheme, String? realm)? f) =>
      _inner.authenticate = f;
  @override
  set authenticateProxy(
          Future<bool> Function(
                  String host, int port, String scheme, String? realm)?
              f) =>
      _inner.authenticateProxy = f;
  @override
  set badCertificateCallback(
          bool Function(X509Certificate cert, String host, int port)? cb) =>
      _inner.badCertificateCallback = cb;
  @override
  set connectionFactory(
          Future<ConnectionTask<Socket>> Function(
                  Uri url, String? proxyHost, int? proxyPort)?
              f) =>
      _inner.connectionFactory = f;
  @override
  set findProxy(String Function(Uri url)? f) => _inner.findProxy = f;
  @override
  set keyLog(void Function(String line)? cb) => _inner.keyLog = cb;

  @override
  void addCredentials(
          Uri url, String realm, HttpClientCredentials credentials) =>
      _inner.addCredentials(url, realm, credentials);
  @override
  void addProxyCredentials(String host, int port, String realm,
          HttpClientCredentials credentials) =>
      _inner.addProxyCredentials(host, port, realm, credentials);

  @override
  void close({bool force = false}) => _inner.close(force: force);
}

class _WrappedRequest implements HttpClientRequest {
  _WrappedRequest(this._inner, this._url);
  final HttpClientRequest _inner;
  final Uri _url;

  @override
  Future<HttpClientResponse> close() async =>
      _WrappedResponse(await _inner.close(), _url);

  @override
  Future<HttpClientResponse> get done =>
      _inner.done.then((r) => _WrappedResponse(r, _url));

  @override
  HttpHeaders get headers => _inner.headers;
  @override
  List<Cookie> get cookies => _inner.cookies;
  @override
  String get method => _inner.method;
  @override
  Uri get uri => _inner.uri;
  @override
  HttpConnectionInfo? get connectionInfo => _inner.connectionInfo;

  @override
  bool get bufferOutput => _inner.bufferOutput;
  @override
  set bufferOutput(bool v) => _inner.bufferOutput = v;
  @override
  int get contentLength => _inner.contentLength;
  @override
  set contentLength(int v) => _inner.contentLength = v;
  @override
  Encoding get encoding => _inner.encoding;
  @override
  set encoding(Encoding v) => _inner.encoding = v;
  @override
  bool get followRedirects => _inner.followRedirects;
  @override
  set followRedirects(bool v) => _inner.followRedirects = v;
  @override
  int get maxRedirects => _inner.maxRedirects;
  @override
  set maxRedirects(int v) => _inner.maxRedirects = v;
  @override
  bool get persistentConnection => _inner.persistentConnection;
  @override
  set persistentConnection(bool v) => _inner.persistentConnection = v;

  @override
  void abort([Object? exception, StackTrace? stackTrace]) =>
      _inner.abort(exception, stackTrace);
  @override
  void add(List<int> data) => _inner.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);
  @override
  Future<void> addStream(Stream<List<int>> stream) => _inner.addStream(stream);
  @override
  Future<void> flush() => _inner.flush();
  @override
  void write(Object? object) => _inner.write(object);
  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      _inner.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => _inner.writeCharCode(charCode);
  @override
  void writeln([Object? object = '']) => _inner.writeln(object);
}

class _WrappedResponse extends Stream<List<int>> implements HttpClientResponse {
  _WrappedResponse(this._inner, this._url);
  final HttpClientResponse _inner;
  final Uri _url;

  @override
  Future<Socket> detachSocket() async {
    final socket = await _inner.detachSocket();
    // This socket is post-upgrade: every byte is a WebSocket frame.
    final connId = RealtimeCapture.instance
        .openConnection(_url.host, _url.port, _url.path.isEmpty ? '/' : _url.path);
    final cap = _SocketCapture(connId);
    return _TeeSocket(socket, cap.onInbound, cap.onOutbound);
  }

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _inner.listen(onData,
        onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  }

  @override
  X509Certificate? get certificate => _inner.certificate;
  @override
  HttpClientResponseCompressionState get compressionState =>
      _inner.compressionState;
  @override
  HttpConnectionInfo? get connectionInfo => _inner.connectionInfo;
  @override
  int get contentLength => _inner.contentLength;
  @override
  List<Cookie> get cookies => _inner.cookies;
  @override
  HttpHeaders get headers => _inner.headers;
  @override
  bool get isRedirect => _inner.isRedirect;
  @override
  bool get persistentConnection => _inner.persistentConnection;
  @override
  String get reasonPhrase => _inner.reasonPhrase;
  @override
  List<RedirectInfo> get redirects => _inner.redirects;
  @override
  int get statusCode => _inner.statusCode;

  @override
  Future<HttpClientResponse> redirect(
          [String? method, Uri? url, bool? followLoops]) =>
      _inner.redirect(method, url, followLoops);
}

/// A transparent [Socket] wrapper that tees inbound bytes (via [listen]) and
/// outbound bytes (via [add] / [addStream] / write*) to callbacks, delegating
/// everything else to [_inner]. Extends [Stream] so the concrete Stream
/// methods funnel through our [listen] without hand-implementing each.
class _TeeSocket extends Stream<Uint8List> implements Socket {
  _TeeSocket(this._inner, this._onInbound, this._onOutbound);

  final Socket _inner;
  final void Function(List<int>) _onInbound;
  final void Function(List<int>) _onOutbound;

  static void _safe(void Function() f) {
    try {
      f();
    } catch (_) {
      // Capture must never break the app's networking.
    }
  }

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _inner.listen(
      (data) {
        _safe(() => _onInbound(data));
        onData?.call(data);
      },
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  void add(List<int> data) {
    _safe(() => _onOutbound(data));
    _inner.add(data);
  }

  @override
  Future<void> addStream(Stream<List<int>> stream) {
    return _inner.addStream(stream.map((chunk) {
      _safe(() => _onOutbound(chunk));
      return chunk;
    }));
  }

  @override
  void write(Object? object) {
    final s = object?.toString() ?? '';
    if (s.isNotEmpty) _safe(() => _onOutbound(utf8.encode(s)));
    _inner.write(object);
  }

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) {
    final s = objects.join(separator);
    if (s.isNotEmpty) _safe(() => _onOutbound(utf8.encode(s)));
    _inner.writeAll(objects, separator);
  }

  @override
  void writeln([Object? object = '']) {
    final s = '${object ?? ''}\n';
    _safe(() => _onOutbound(utf8.encode(s)));
    _inner.writeln(object);
  }

  @override
  void writeCharCode(int charCode) => _inner.writeCharCode(charCode);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);

  @override
  Future<void> flush() => _inner.flush();

  @override
  Future<void> close() => _inner.close();

  @override
  Future<void> get done => _inner.done;

  @override
  Encoding get encoding => _inner.encoding;

  @override
  set encoding(Encoding value) => _inner.encoding = value;

  @override
  InternetAddress get address => _inner.address;

  @override
  int get port => _inner.port;

  @override
  InternetAddress get remoteAddress => _inner.remoteAddress;

  @override
  int get remotePort => _inner.remotePort;

  @override
  void destroy() => _inner.destroy();

  @override
  bool setOption(SocketOption option, bool enabled) =>
      _inner.setOption(option, enabled);

  @override
  Uint8List getRawOption(RawSocketOption option) => _inner.getRawOption(option);

  @override
  void setRawOption(RawSocketOption option) => _inner.setRawOption(option);
}
