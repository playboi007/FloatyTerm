/// Dev-only, full-fidelity HTTP recorder for Dart and Flutter apps.
///
/// Installs an [HttpOverrides] that wraps every [HttpClient] the app creates,
/// tees the request and response bytes as they flow, and streams each finished
/// call to FloatyTerm's loopback relay. Stop the recording from the terminal
/// and export it as JSON, HAR or Markdown.
///
/// ```dart
/// void main() {
///   assert(() { FloatyNet.start(label: 'admin-app'); return true; }());
///   runApp(const MyApp());
/// }
/// ```
///
/// The `assert` idiom matters: the body of an assert is stripped from release
/// builds, so the recorder cannot ship by accident.
///
/// **This records everything, unredacted** — `Authorization` headers, cookies,
/// and request and response bodies, verbatim, because the point is to be able
/// to replay the request afterwards. Never enable it in a build you ship.
///
/// ## Why this exists next to the VM Service collector
///
/// `floaty net start --vm <uri>` already records `dart:io` HTTP with no code
/// in the app at all, and it should be the default choice. This package earns
/// its place in three cases the VM profiler cannot cover:
///
///   - a **release or profile build on a real device**, where no VM Service
///     is attached;
///   - **user-action context** — [FloatyNet.tag] attaches the current screen
///     or action to every request that follows, so the export can say what
///     the user did to cause the call;
///   - **manual records** ([FloatyNet.record]) for traffic no HTTP client
///     owns: a gRPC call, a WebSocket frame, a platform-channel fetch.
///
/// Both collectors can run at once. Each event carries its `source`, so the
/// export keeps them apart.
library floaty_net_recorder;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

/// Controls the recorder.
class FloatyNet {
  FloatyNet._();

  static const String _defaultRelay = 'http://127.0.0.1:7777/net';

  static _Sender? _sender;
  static HttpOverrides? _previous;
  static bool _installed = false;

  /// Per-request context attached to everything recorded from now on.
  static final Map<String, Object?> _context = <String, Object?>{};

  /// Bodies larger than this are truncated, and the event says so. The relay
  /// applies its own cap as well; the smaller of the two wins.
  static int maxBody = 5 * 1024 * 1024;

  /// Prints what the recorder is doing, to stdout. Off by default because a
  /// dev tool must not spam the app's console — but a recorder that cannot
  /// reach the relay is otherwise indistinguishable from one that has nothing
  /// to send, which is the single most confusing way for this to fail.
  static bool debug = false;

  static void _log(String message) {
    if (debug) print('[floaty_net] $message');
  }

  /// True while the overrides are installed.
  static bool get isRecording => _installed;

  /// Starts recording. [label] must match the label the terminal recorded
  /// with (`floaty net start --label <label>`) — the relay files events by
  /// label, and a mismatch is the one way to get an empty recording while
  /// everything looks healthy.
  ///
  /// Nothing is written to disk unless a session is recording on the
  /// FloatyTerm side, so leaving this installed in a dev build is harmless
  /// beyond the cost of a dropped POST per request.
  static void start({
    String label = 'app',
    String relay = _defaultRelay,
    int? maxBodyBytes,
  }) {
    if (_installed) return;
    if (maxBodyBytes != null) maxBody = maxBodyBytes;

    // Built BEFORE the overrides are installed, so the sender's own client is
    // an unwrapped one. A sender whose POSTs were themselves recorded would
    // record its own recording, forever.
    _sender = _Sender(label: label, endpoint: Uri.parse(relay));

    _previous = HttpOverrides.current;
    HttpOverrides.global = _FloatyHttpOverrides(_previous);
    _installed = true;
  }

  /// Stops recording and flushes whatever is queued. Restores any overrides
  /// that were installed before [start].
  static Future<void> stop() async {
    if (!_installed) return;
    HttpOverrides.global = _previous;
    _previous = null;
    _installed = false;
    await _sender?.close();
    _sender = null;
  }

  /// Attaches context to every request recorded from now on — the thing the
  /// VM profiler structurally cannot know.
  ///
  /// ```dart
  /// FloatyNet.tag('screen', 'checkout');
  /// FloatyNet.tag('action', 'tapped Pay');
  /// ```
  ///
  /// Pass null to clear one key; [clearTags] clears them all.
  static void tag(String key, Object? value) {
    if (value == null) {
      _context.remove(key);
    } else {
      _context[key] = value;
    }
  }

  static void clearTags() => _context.clear();

  /// Records one event by hand — for traffic that never touches an
  /// [HttpClient]. Anything you put in the map is kept verbatim; the fields
  /// the exporter understands are `method`, `url`, `status`, `ms`,
  /// `req_headers`, `res_headers`, `req_body`, `res_body`, `error`.
  static void record(Map<String, Object?> event) {
    final sender = _sender;
    if (sender == null) return;
    sender.add(<String, Object?>{
      'kind': 'network',
      ..._contextFields(),
      ...event,
    });
  }

  static Map<String, Object?> _contextFields() =>
      _context.isEmpty ? const {} : <String, Object?>{'context': Map.of(_context)};

  static void _emit(Map<String, Object?> event) {
    _sender?.add(<String, Object?>{..._contextFields(), ...event});
  }
}

// ---------------------------------------------------------------------------
// Overrides + client wrapper
// ---------------------------------------------------------------------------

class _FloatyHttpOverrides extends HttpOverrides {
  _FloatyHttpOverrides(this._previous);

  final HttpOverrides? _previous;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    // Chain, never replace: an app that already installed overrides (a
    // certificate pin, a proxy) must keep them.
    final inner = _previous?.createHttpClient(context) ??
        super.createHttpClient(context);
    return _RecordingHttpClient(inner);
  }

  @override
  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) =>
      _previous?.findProxyFromEnvironment(url, environment) ??
      super.findProxyFromEnvironment(url, environment);
}

/// Forwards every member to the real client and wraps only `openUrl`, which
/// every other request method funnels through.
class _RecordingHttpClient implements HttpClient {
  _RecordingHttpClient(this._inner);

  final HttpClient _inner;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    final request = await _inner.openUrl(method, url);
    // Never record the pipe that carries the recording.
    if (_Sender.isRelay(url)) return request;
    return _RecordingRequest(request, method, url);
  }

  @override
  Future<HttpClientRequest> open(
          String method, String host, int port, String path) =>
      openUrl(method, Uri(scheme: 'http', host: host, port: port, path: path));

  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);
  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('POST', url);
  @override
  Future<HttpClientRequest> putUrl(Uri url) => openUrl('PUT', url);
  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => openUrl('DELETE', url);
  @override
  Future<HttpClientRequest> patchUrl(Uri url) => openUrl('PATCH', url);
  @override
  Future<HttpClientRequest> headUrl(Uri url) => openUrl('HEAD', url);

  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      open('GET', host, port, path);
  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      open('POST', host, port, path);
  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      open('PUT', host, port, path);
  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      open('DELETE', host, port, path);
  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      open('PATCH', host, port, path);
  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      open('HEAD', host, port, path);

  @override
  Duration get idleTimeout => _inner.idleTimeout;
  @override
  set idleTimeout(Duration value) => _inner.idleTimeout = value;

  @override
  Duration? get connectionTimeout => _inner.connectionTimeout;
  @override
  set connectionTimeout(Duration? value) => _inner.connectionTimeout = value;

  @override
  int? get maxConnectionsPerHost => _inner.maxConnectionsPerHost;
  @override
  set maxConnectionsPerHost(int? value) => _inner.maxConnectionsPerHost = value;

  @override
  bool get autoUncompress => _inner.autoUncompress;
  @override
  set autoUncompress(bool value) => _inner.autoUncompress = value;

  @override
  String? get userAgent => _inner.userAgent;
  @override
  set userAgent(String? value) => _inner.userAgent = value;

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
          bool Function(X509Certificate cert, String host, int port)? callback) =>
      _inner.badCertificateCallback = callback;

  @override
  set connectionFactory(
          Future<ConnectionTask<Socket>> Function(
                  Uri url, String? proxyHost, int? proxyPort)?
              f) =>
      _inner.connectionFactory = f;

  @override
  set findProxy(String Function(Uri url)? f) => _inner.findProxy = f;

  @override
  set keyLog(Function(String line)? callback) => _inner.keyLog = callback;

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

// ---------------------------------------------------------------------------
// Request / response teeing
// ---------------------------------------------------------------------------

/// Wraps one request, collecting the bytes written to it and, once the
/// response arrives, the bytes read back.
class _RecordingRequest implements HttpClientRequest {
  _RecordingRequest(this._inner, this.method, this.uri)
      : _started = DateTime.now();

  final HttpClientRequest _inner;
  final DateTime _started;

  @override
  final String method;
  @override
  final Uri uri;

  final BytesBuilder _body = BytesBuilder(copy: false);
  int _bodyBytes = 0;
  bool _overflowed = false;

  void _collect(List<int> data) {
    _bodyBytes += data.length;
    if (_body.length >= FloatyNet.maxBody) {
      _overflowed = true;
      return;
    }
    _body.add(data);
  }

  @override
  Future<HttpClientResponse> close() async {
    final requestHeaders = _snapshotHeaders(_inner.headers);
    FloatyNet._log('capturing $method $uri');
    try {
      final response = await _inner.close();
      return _RecordingResponse(
        response,
        onDone: (bodyBytes, truncated, totalBytes, error) {
          _emit(
            requestHeaders: requestHeaders,
            response: response,
            resBody: bodyBytes,
            resTruncated: truncated,
            resTotal: totalBytes,
            error: error,
          );
        },
      );
    } catch (e) {
      // A connection failure never produces a response, and a recording that
      // silently omits the calls that failed is worse than no recording.
      _emit(requestHeaders: requestHeaders, response: null, error: '$e');
      rethrow;
    }
  }

  void _emit({
    required Map<String, List<String>> requestHeaders,
    HttpClientResponse? response,
    List<int>? resBody,
    bool resTruncated = false,
    int? resTotal,
    Object? error,
  }) {
    final ms = DateTime.now().difference(_started).inMicroseconds / 1000.0;
    final reqBody = _body.toBytes();

    final event = <String, Object?>{
      'kind': 'network',
      'protocol': 'http',
      'method': method,
      'url': uri.toString(),
      'ms': ms,
      'req_headers': requestHeaders,
      if (uri.hasQuery) 'req_query': uri.queryParameters,
    };

    _attachBody(event, 'req', reqBody, _overflowed, _bodyBytes);

    if (response != null) {
      event['status'] = response.statusCode;
      event['status_text'] = response.reasonPhrase;
      event['res_headers'] = _snapshotHeaders(response.headers);
      event['is_redirect'] = response.isRedirect;
      if (response.redirects.isNotEmpty) {
        event['redirects'] = response.redirects
            .map((r) => <String, Object?>{
                  'status': r.statusCode,
                  'method': r.method,
                  'location': r.location.toString(),
                })
            .toList();
      }
      final info = response.connectionInfo;
      if (info != null) {
        event['remote_address'] = info.remoteAddress.address;
        event['remote_port'] = info.remotePort;
      }
      if (resBody != null) {
        _attachBody(event, 'res', resBody, resTruncated, resTotal ?? resBody.length);
      }
    }
    if (error != null) event['error'] = '$error';

    FloatyNet._emit(event);
  }

  /// Text bodies go over as text so the export can show and replay them;
  /// anything that is not valid UTF-8 goes as base64 with a flag, because a
  /// lossy decode corrupts an image and still looks like a successful capture.
  static void _attachBody(Map<String, Object?> event, String prefix,
      List<int> bytes, bool truncated, int totalBytes) {
    if (bytes.isEmpty) return;
    try {
      event['${prefix}_body'] = utf8.decode(bytes);
    } catch (_) {
      event['${prefix}_body'] = base64.encode(bytes);
      event['${prefix}_body_base64'] = true;
    }
    event['${prefix}_body_bytes'] = totalBytes;
    if (truncated) event['${prefix}_body_truncated'] = true;
  }

  static Map<String, List<String>> _snapshotHeaders(HttpHeaders headers) {
    final out = <String, List<String>>{};
    headers.forEach((name, values) => out[name] = List<String>.of(values));
    return out;
  }

  // --- IOSink surface: tee, then forward ---

  @override
  void add(List<int> data) {
    _collect(data);
    _inner.add(data);
  }

  @override
  Future<void> addStream(Stream<List<int>> stream) =>
      _inner.addStream(stream.map((chunk) {
        _collect(chunk);
        return chunk;
      }));

  @override
  void write(Object? object) => add(encoding.encode('$object'));

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      write(objects.join(separator));

  @override
  void writeln([Object? object = '']) => write('$object\n');

  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);

  @override
  Future<void> flush() => _inner.flush();

  @override
  void abort([Object? exception, StackTrace? stackTrace]) =>
      _inner.abort(exception, stackTrace);

  @override
  Encoding get encoding => _inner.encoding;
  @override
  set encoding(Encoding value) => _inner.encoding = value;

  @override
  bool get bufferOutput => _inner.bufferOutput;
  @override
  set bufferOutput(bool value) => _inner.bufferOutput = value;

  @override
  int get contentLength => _inner.contentLength;
  @override
  set contentLength(int value) => _inner.contentLength = value;

  @override
  bool get followRedirects => _inner.followRedirects;
  @override
  set followRedirects(bool value) => _inner.followRedirects = value;

  @override
  int get maxRedirects => _inner.maxRedirects;
  @override
  set maxRedirects(int value) => _inner.maxRedirects = value;

  @override
  bool get persistentConnection => _inner.persistentConnection;
  @override
  set persistentConnection(bool value) => _inner.persistentConnection = value;

  @override
  HttpHeaders get headers => _inner.headers;
  @override
  List<Cookie> get cookies => _inner.cookies;
  @override
  HttpConnectionInfo? get connectionInfo => _inner.connectionInfo;
  @override
  Future<HttpClientResponse> get done => _inner.done;
}

/// Passes the response body through untouched while keeping a copy.
///
/// Extends [StreamView] so every `Stream` method comes for free and only the
/// `HttpClientResponse` surface has to be forwarded.
class _RecordingResponse extends StreamView<List<int>>
    implements HttpClientResponse {
  _RecordingResponse(this._inner, {required this.onDone})
      : super(_tee(_inner, onDone));

  final HttpClientResponse _inner;
  final void Function(List<int> body, bool truncated, int total, Object? error)
      onDone;

  /// The event fires when the body stream ENDS, not when the headers arrive —
  /// otherwise the recording holds a response with no body. A caller that
  /// never drains the stream therefore never produces an event, which is the
  /// same rule the response itself follows.
  static Stream<List<int>> _tee(
    HttpClientResponse inner,
    void Function(List<int>, bool, int, Object?) onDone,
  ) {
    final buffer = BytesBuilder(copy: false);
    var total = 0;
    var truncated = false;
    return inner.transform(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleData: (chunk, sink) {
          total += chunk.length;
          if (buffer.length < FloatyNet.maxBody) {
            buffer.add(chunk);
          } else {
            truncated = true;
          }
          sink.add(chunk);
        },
        handleError: (error, stack, sink) {
          onDone(buffer.toBytes(), truncated, total, error);
          sink.addError(error, stack);
        },
        handleDone: (sink) {
          onDone(buffer.toBytes(), truncated, total, null);
          sink.close();
        },
      ),
    );
  }

  @override
  int get statusCode => _inner.statusCode;
  @override
  String get reasonPhrase => _inner.reasonPhrase;
  @override
  int get contentLength => _inner.contentLength;
  @override
  HttpClientResponseCompressionState get compressionState =>
      _inner.compressionState;
  @override
  bool get persistentConnection => _inner.persistentConnection;
  @override
  bool get isRedirect => _inner.isRedirect;
  @override
  List<RedirectInfo> get redirects => _inner.redirects;
  @override
  HttpHeaders get headers => _inner.headers;
  @override
  List<Cookie> get cookies => _inner.cookies;
  @override
  X509Certificate? get certificate => _inner.certificate;
  @override
  HttpConnectionInfo? get connectionInfo => _inner.connectionInfo;
  @override
  Future<HttpClientResponse> redirect(
          [String? method, Uri? url, bool? followLoops]) =>
      _inner.redirect(method, url, followLoops);
  @override
  Future<Socket> detachSocket() => _inner.detachSocket();
}

// ---------------------------------------------------------------------------
// Relay sender
// ---------------------------------------------------------------------------

/// Batches events and POSTs them to the relay.
///
/// Batching is not an optimization here: a chatty screen can fire dozens of
/// requests, and one POST each would add more traffic than it records — and
/// every one of those POSTs would show up in the app's own profile.
class _Sender {
  _Sender({required this.label, required this.endpoint})
      : _client = HttpClient()..connectionTimeout = const Duration(seconds: 2);

  static const int _maxQueue = 500;

  final String label;
  final Uri endpoint;
  final HttpClient _client;
  final List<Map<String, Object?>> _queue = <Map<String, Object?>>[];

  Timer? _timer;
  Future<void>? _inFlight;
  bool _closed = false;

  static bool isRelay(Uri url) =>
      (url.host == '127.0.0.1' || url.host == 'localhost') && url.port == 7777;

  void add(Map<String, Object?> event) {
    if (_closed) return;
    // Drop the OLDEST when the relay is unreachable. The newest events are the
    // ones the user is looking at; an unbounded queue in a dev build is a leak
    // that gets blamed on the app.
    if (_queue.length >= _maxQueue) _queue.removeAt(0);
    _queue.add(event);
    _timer ??= Timer(const Duration(milliseconds: 300), () {
      _timer = null;
      _pump();
    });
  }

  /// Starts the send loop, or joins the one already running, and hands back a
  /// future that completes when it stops. Returning the SAME future to every
  /// caller is what makes [close] able to wait: an earlier design fired and
  /// forgot, so a close during an in-flight batch force-killed the client
  /// mid-POST and the whole batch vanished — a recording that looked healthy
  /// and held nothing.
  Future<void> _pump() {
    final running = _inFlight;
    if (running != null) return running;
    final started = _loop().whenComplete(() => _inFlight = null);
    _inFlight = started;
    return started;
  }

  /// One POST stays near this size. The relay rejects oversized requests, and
  /// a batch of several large bodies would lose ALL of them to one rejection.
  static const int _maxBatchBytes = 8 * 1024 * 1024;

  static int _approxSize(Map<String, Object?> e) {
    final req = e['req_body'];
    final res = e['res_body'];
    return 2048 + (req is String ? req.length : 0) + (res is String ? res.length : 0);
  }

  Future<void> _loop() async {
    while (_queue.isNotEmpty) {
      final batch = <Map<String, Object?>>[];
      var bytes = 0;
      while (_queue.isNotEmpty &&
          (batch.isEmpty || bytes + _approxSize(_queue.first) <= _maxBatchBytes)) {
        final event = _queue.removeAt(0);
        bytes += _approxSize(event);
        batch.add(event);
      }
      await _post(batch);
    }
  }

  Future<void> _post(List<Map<String, Object?>> batch) async {
    try {
      final payload = utf8.encode(jsonEncode(<String, Object?>{
        'label': label,
        'source': 'dart-hook',
        'events': batch,
      }));
      final request = await _client.postUrl(endpoint);
      request.headers.contentType = ContentType.json;
      // Declare the length instead of streaming it. A body written with
      // `write` goes out chunked, and chunked framing is the kind of detail a
      // receiving server is allowed to get wrong — this one did.
      request.contentLength = payload.length;
      request.add(payload);
      final response = await request.close();
      await response.drain<void>();
      FloatyNet._log('sent ${batch.length} events → ${response.statusCode}');
    } catch (e) {
      // FloatyTerm is not running, or nothing is recording. Either way this is
      // a dev tool talking to a tool: never throw into the app being recorded.
      FloatyNet._log('send failed (${batch.length} events): $e');
    }
  }

  /// Flushes everything, THEN closes. Two pumps on purpose: the first waits
  /// out a batch already in flight, the second sends whatever was queued
  /// while that one was running.
  Future<void> close() async {
    _timer?.cancel();
    _timer = null;
    await _pump();
    await _pump();
    _closed = true;
    _client.close(force: true);
  }
}
